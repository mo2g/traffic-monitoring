import Foundation
import UserNotifications

/// 每进程的累计统计
struct ProcessStats {
    var identity: ProcessIdentifier
    var icon: String
    /// 已落库的历史累计
    var historicalIn: Int64 = 0
    var historicalOut: Int64 = 0

    /// 尚未落库的实时累计
    var liveIn: Int64 = 0
    var liveOut: Int64 = 0
    /// 最近一帧的瞬时速率
    var rxRate: Double = 0
    var txRate: Double = 0
    var sampleCount: Int = 0

    var totalIn: Int64 { historicalIn + liveIn }
    var totalOut: Int64 { historicalOut + liveOut }
    var totalBytes: Int64 { totalIn + totalOut }
}

/// 采集管线：帧 → 身份解析 → 聚合 → 内存统计 → 分桶落库 → UI 快照
///
/// 整条链路都在这个 actor 上跑，**不占用主线程**。
/// 旧实现把 `DeltaCalculator` / `ProcessAggregator`（含 libproc 与 LaunchServices 调用）
/// 放在 `@MainActor` 的 `processSnapshot` 里，等于让主线程做 syscall。
actor TrafficPipeline {
    static let shared = TrafficPipeline()

    // MARK: 状态

    private var stats: [String: ProcessStats] = [:]
    private var resolver = ProcessIdentityResolver()

    /// 待落库的时间桶：bucketStart → processKey → 增量
    private var buckets: [TimeInterval: [String: (bytesIn: Int64, bytesOut: Int64)]] = [:]
    /// 桶里已聚合但还没写库的行数（用于日志/诊断）
    private(set) var pendingRowCount = 0

    private var alertRules: [AlertRule] = []
    private var alertThrottle: [String: Date] = [:]
    private let alertThrottleInterval: TimeInterval = 60

    /// UI 推送节流：窗口不可见时完全不生成快照，采集与落库照常
    private var uiVisible = true
    private var lastPushedAt = Date.distantPast

    private init() {}

    // MARK: - 生命周期

    /// 用数据库里某个时间窗的汇总替换「历史」部分。
    ///
    /// 启动时调一次，之后每次切换时间范围再调一次 —— 所以必须是幂等的替换，
    /// 而不是累加。
    ///
    /// 账目关系：
    /// - `historical` = 该时间窗内已落库的字节
    /// - `live` = 已采集但还没落库的字节（`flush()` 会把它转进 historical）
    /// - `total = historical + live`，两边不重不漏
    ///
    /// 窗口变化后，原来有数据、新窗口里没有的进程，其 historical 要清零，
    /// 否则会把窗口外的流量留在总数里。已解析过的身份（含图标路径）保留不动。
    func reloadHistorical(_ summaries: [ProcessSummary]) {
        var remaining = Set(stats.keys)

        for h in summaries {
            remaining.remove(h.processKey)
            if var s = stats[h.processKey] {
                s.historicalIn = h.totalIn
                s.historicalOut = h.totalOut
                s.sampleCount = h.sampleCount
                stats[h.processKey] = s
            } else {
                let identity = ProcessIdentifier(
                    bundleId: h.bundleId,
                    execName: h.processKey,
                    displayName: h.displayName
                )
                stats[h.processKey] = ProcessStats(
                    identity: identity,
                    icon: IconCatalog.icon(for: h.displayName),
                    historicalIn: h.totalIn,
                    historicalOut: h.totalOut,
                    sampleCount: h.sampleCount
                )
            }
        }

        for key in remaining {
            guard var s = stats[key] else { continue }
            s.historicalIn = 0
            s.historicalOut = 0
            stats[key] = s
            // 窗口内既无历史也无实时数据的进程直接移出列表
            if s.liveIn == 0, s.liveOut == 0, s.rxRate == 0, s.txRate == 0 {
                stats.removeValue(forKey: key)
            }
        }

        lastPushedAt = .distantPast   // 让下一帧立刻把新窗口的数字推给 UI
    }

    func setAlertRules(_ rules: [AlertRule]) { alertRules = rules }

    func reset() {
        stats.removeAll()
        buckets.removeAll()
        pendingRowCount = 0
        alertThrottle.removeAll()
        resolver.reset()
    }

    // MARK: - 摄入一帧

    /// 处理一帧采集数据。
    ///
    /// - Returns: 需要推送给 UI 的快照；不到刷新节拍或窗口不可见时返回 nil。
    ///   这样主线程在多数帧上**完全不被唤醒**。
    func ingest(_ frame: TrafficFrame) -> DashboardSnapshot? {
        // 首帧的「增量」是各连接自建立以来的累计值，只用来建立基线和活跃进程集合
        guard !frame.isBaseline else {
            for d in frame.deltas { _ = ensureStats(pid: d.pid, execName: d.execName) }
            return pushIfDue(at: frame.timestamp)
        }

        // 上一帧还活跃、这一帧没数据的进程，速率归零
        var touched = Set<String>()
        touched.reserveCapacity(frame.deltas.count)

        let interval = max(frame.interval, Constants.minRateInterval)
        let bucket = (frame.timestamp.timeIntervalSince1970 / Constants.storageBucketSeconds)
            .rounded(.down) * Constants.storageBucketSeconds

        var aggregated: [String: (bytesIn: Int64, bytesOut: Int64, identity: ProcessIdentifier)] = [:]
        aggregated.reserveCapacity(frame.deltas.count)

        for d in frame.deltas {
            let identity = resolver.identity(pid: d.pid, execName: d.execName)
            let key = identity.key
            if let cur = aggregated[key] {
                aggregated[key] = (cur.bytesIn + d.bytesIn, cur.bytesOut + d.bytesOut, cur.identity)
            } else {
                aggregated[key] = (d.bytesIn, d.bytesOut, identity)
            }
        }

        for (key, v) in aggregated {
            touched.insert(key)
            var s = stats[key] ?? ProcessStats(
                identity: v.identity,
                icon: IconCatalog.icon(for: v.identity.displayName)
            )
            s.liveIn += v.bytesIn
            s.liveOut += v.bytesOut
            s.rxRate = Double(v.bytesIn) / interval
            s.txRate = Double(v.bytesOut) / interval
            s.sampleCount += 1
            stats[key] = s

            // 分桶聚合，稍后批量落库
            if buckets[bucket]?[key] == nil { pendingRowCount += 1 }
            var slot = buckets[bucket] ?? [:]
            let cur = slot[key] ?? (0, 0)
            slot[key] = (cur.bytesIn + v.bytesIn, cur.bytesOut + v.bytesOut)
            buckets[bucket] = slot
        }

        // 未出现在本帧的进程速率清零（否则表格会一直显示上一次的速率）
        for (key, var s) in stats where !touched.contains(key) {
            guard s.rxRate != 0 || s.txRate != 0 else { continue }
            s.rxRate = 0
            s.txRate = 0
            stats[key] = s
        }

        checkAlerts(aggregated, interval: interval)
        return pushIfDue(at: frame.timestamp)
    }

    // MARK: - UI 推送节流

    func setUIVisible(_ visible: Bool) {
        uiVisible = visible
        if visible { lastPushedAt = .distantPast }   // 重新可见时立刻补一帧
    }

    private func pushIfDue(at now: Date) -> DashboardSnapshot? {
        guard uiVisible else { return nil }
        guard now.timeIntervalSince(lastPushedAt) >= Constants.uiRefreshInterval else { return nil }
        lastPushedAt = now
        return makeSnapshot()
    }

    private func ensureStats(pid: Int32, execName: String) -> ProcessIdentifier {
        let identity = resolver.identity(pid: pid, execName: execName)
        if stats[identity.key] == nil {
            stats[identity.key] = ProcessStats(
                identity: identity,
                icon: IconCatalog.icon(for: identity.displayName)
            )
        }
        return identity
    }

    // MARK: - UI 快照

    func makeSnapshot() -> DashboardSnapshot {
        var rows: [ProcessRow] = []
        rows.reserveCapacity(stats.count)
        var rx = 0.0, tx = 0.0, total: Int64 = 0

        for (key, s) in stats {
            rx += s.rxRate
            tx += s.txRate
            total += s.totalBytes
            rows.append(ProcessRow(
                key: key,
                bundleId: s.identity.bundleId,
                displayName: s.identity.displayName,
                icon: s.icon,
                iconPath: s.identity.iconPath,
                totalIn: s.totalIn,
                totalOut: s.totalOut,
                rxRate: s.rxRate,
                txRate: s.txRate
            ))
        }
        rows.sort { $0.totalBytes > $1.totalBytes }
        return DashboardSnapshot(rows: rows, totalRxRate: rx, totalTxRate: tx, totalBytes: total)
    }

    // MARK: - 落库

    /// 把已经封口的时间桶批量写库（当前正在累加的桶保留）
    ///
    /// - Parameter force: 停止采集时传 true，连当前桶一起写出
    func flush(force: Bool = false) async {
        guard !buckets.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let currentBucket = (now / Constants.storageBucketSeconds)
            .rounded(.down) * Constants.storageBucketSeconds

        let ready = buckets.keys.filter { force || $0 < currentBucket }
        guard !ready.isEmpty else { return }

        var events: [TrafficEvent] = []
        for bucket in ready {
            guard let slot = buckets[bucket] else { continue }
            for (key, v) in slot {
                let s = stats[key]
                events.append(TrafficEvent(
                    id: nil,
                    timestamp: bucket,
                    interval: Constants.storageBucketSeconds,
                    processKey: key,
                    bundleId: s?.identity.bundleId,
                    displayName: s?.identity.displayName ?? key,
                    bytesIn: v.bytesIn,
                    bytesOut: v.bytesOut
                ))
            }
        }
        guard !events.isEmpty else { return }

        do {
            try await DataStore.shared.insertEvents(events)
        } catch {
            await LogStore.shared.log("批量写入 DB 失败: \(error)", level: .error, tag: "Pipeline")
            return  // 桶保留，下次重试
        }

        for bucket in ready { buckets.removeValue(forKey: bucket) }
        pendingRowCount = max(0, pendingRowCount - events.count)

        // 已落库的部分从 live 转入 historical
        for e in events {
            guard var s = stats[e.processKey] else { continue }
            s.historicalIn += e.bytesIn
            s.historicalOut += e.bytesOut
            s.liveIn = max(0, s.liveIn - e.bytesIn)
            s.liveOut = max(0, s.liveOut - e.bytesOut)
            stats[e.processKey] = s
        }
    }

    // MARK: - 告警

    private func checkAlerts(
        _ aggregated: [String: (bytesIn: Int64, bytesOut: Int64, identity: ProcessIdentifier)],
        interval: TimeInterval
    ) {
        let enabled = alertRules.filter(\.enabled)
        guard !enabled.isEmpty, !aggregated.isEmpty else { return }

        let now = Date()
        for (key, v) in aggregated {
            let delta = ProcessDelta(
                identifier: v.identity,
                bytesIn: v.bytesIn,
                bytesOut: v.bytesOut,
                interval: interval
            )
            for rule in enabled where rule.isTriggered(by: delta) {
                let throttleKey = rule.id.uuidString + "_" + key
                if let last = alertThrottle[throttleKey],
                   now.timeIntervalSince(last) < alertThrottleInterval { continue }
                alertThrottle[throttleKey] = now
                postAlert(rule: rule, delta: delta)
            }
        }
    }

    private func postAlert(rule: AlertRule, delta: ProcessDelta) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let body: String
        if let tb = rule.thresholdBytes {
            body = "\(delta.identifier.displayName) 流量 \(ByteFormatter.string(bytes: delta.totalBytes)) 超过 \(ByteFormatter.string(bytes: tb))"
        } else if let tr = rule.thresholdRate {
            body = "\(delta.identifier.displayName) 速率 \(ByteFormatter.rateString(bytesPerSecond: delta.totalRate)) 超过 \(ByteFormatter.rateString(bytesPerSecond: tr))"
        } else { return }

        let content = UNMutableNotificationContent()
        content.title = "TrafficMonitor 告警"
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

// MARK: - 图标

/// 进程名 → SF Symbol
///
/// 结果在进程首次出现时算一次并存进 `ProcessStats`，不再每次重建列表都跑一遍。
enum IconCatalog {
    static func icon(for name: String) -> String {
        let l = name.lowercased()
        if l.contains("chrome") || l.contains("edge") { return "globe" }
        if l.contains("safari")  { return "safari" }
        if l.contains("firefox") { return "flame" }
        if l.contains("code")    { return "chevron.left.forwardslash.chevron.right" }
        if l.contains("wechat")  { return "message" }
        if l.contains("telegram") { return "paperplane" }
        if l.contains("slack")   { return "number" }
        if l.contains("discord") { return "headphones" }
        if l.contains("zoom")    { return "video" }
        if l.contains("spotify") { return "music.note" }
        if l.contains("mail")    { return "envelope" }
        if l.contains("terminal") || l.contains("iterm") { return "terminal" }
        if l.contains("shadowrocket") || l.contains("surge") || l.contains("clash") { return "arrow.triangle.swap" }
        return "app.dashed"
    }
}
