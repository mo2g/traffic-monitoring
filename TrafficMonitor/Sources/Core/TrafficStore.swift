import Foundation

/// 每进程的流量累计数据（纯值类型，线程安全）
struct ProcessStats {
    var historicalIn:  Int64 = 0
    var historicalOut: Int64 = 0
    var liveDeltaIn:   Int64 = 0
    var liveDeltaOut:  Int64 = 0
    var displayName:   String = ""
    var bundleId:      String?
    var sampleCount:   Int   = 0

    var totalIn:  Int64 { historicalIn  + liveDeltaIn  }
    var totalOut: Int64 { historicalOut + liveDeltaOut }
    var totalBytes: Int64 { totalIn + totalOut }
}

/// 采集内存缓存 + 批量持久化
///
/// 职责：
/// - 首次打开：nettop 获取活跃进程 → SQL 查历史 → 初始化累加器
/// - 每个 tick：接收 ProcessDelta → 累加到 liveDelta → 入队 pendingEvents
/// - UI 刷新(1s)：DashboardVM 直接读取内存快照
/// - 批量保存(5s)：pendingEvents 批量 INSERT → 将 liveDelta 转为 historical
actor TrafficStore {
    static let shared = TrafficStore()

    /// per-processKey 累计统计
    private var stats: [String: ProcessStats] = [:]

    /// 待批量写入的 TrafficEvent 队列
    private var pendingEvents: [TrafficEvent] = []

    /// 最近一次增量列表（供 UI 读取实时速率）
    private(set) var latestDeltas: [ProcessDelta] = []

    /// 所有已跟踪的 processKey（供初始化查询）
    private(set) var trackedKeys: Set<String> = []

    private init() {}

    // MARK: - Init

    /// 首次启动：用活跃进程键 + 历史查询初始化累加器
    func initialize(activeDeltas: [ProcessDelta], historical: [ProcessSummary]) async {
        // 合并实时 delta 的元数据（displayName, bundleId）
        var merged = stats

        for d in activeDeltas {
            let key = d.identifier.description
            var s = merged[key] ?? ProcessStats()
            s.displayName = d.identifier.displayName
            s.bundleId    = d.identifier.bundleId
            merged[key] = s
        }

        // 合并历史数据
        for h in historical {
            var s = merged[h.processKey] ?? ProcessStats()
            s.historicalIn  = h.totalIn
            s.historicalOut = h.totalOut
            s.displayName   = h.displayName
            s.bundleId      = h.bundleId
            s.sampleCount   = h.sampleCount
            merged[h.processKey] = s
        }

        stats = merged
        trackedKeys = Set(merged.keys)
        latestDeltas = activeDeltas
    }

    // MARK: - Tick

    /// 接收本次采集增量 → 累加到内存 + 入队待保存
    func accumulate(deltas: [ProcessDelta], timestamp: TimeInterval, interval: TimeInterval) {
        latestDeltas = deltas

        for d in deltas {
            let key = d.identifier.description
            var s = stats[key] ?? ProcessStats(
                displayName: d.identifier.displayName,
                bundleId: d.identifier.bundleId
            )
            s.liveDeltaIn  += d.bytesIn
            s.liveDeltaOut += d.bytesOut
            s.sampleCount  += 1
            stats[key] = s
            trackedKeys.insert(key)

            pendingEvents.append(TrafficEvent(
                id: nil,
                timestamp: timestamp,
                interval: interval,
                processKey: key,
                bundleId: d.identifier.bundleId,
                displayName: d.identifier.displayName,
                bytesIn: d.bytesIn,
                bytesOut: d.bytesOut
            ))
        }
    }

    // MARK: - Read (for UI)

    /// 返回当前所有进程的统计数据快照（按 totalBytes 降序）
    func snapshot() -> [(key: String, stats: ProcessStats)] {
        stats
            .map { (key: $0.key, stats: $0.value) }
            .sorted { $0.stats.totalBytes > $1.stats.totalBytes }
    }

    // MARK: - Batch Save

    /// 将 pendingEvents 批量写入 SQLite，并将 liveDelta 转为 historical
    func flushPending() async {
        guard !pendingEvents.isEmpty else { return }

        let batch = pendingEvents
        pendingEvents.removeAll()

        // 写入 DB
        do {
            try await DataStore.shared.insertEvents(batch)
        } catch {
            await LogStore.shared.log("批量写入 DB 失败: \(error)", level: .error, tag: "TrafficStore")
            // 失败时不丢数据 — 重新入队
            pendingEvents.insert(contentsOf: batch, at: 0)
            return
        }

        // 将 liveDelta 转为 historical
        for event in batch {
            let key = event.processKey
            if var s = stats[key] {
                s.historicalIn  += s.liveDeltaIn
                s.historicalOut += s.liveDeltaOut
                s.liveDeltaIn   = 0
                s.liveDeltaOut  = 0
                stats[key] = s
            }
        }
    }

    /// 清空所有内存数据（停止时调用）
    func reset() {
        stats.removeAll()
        pendingEvents.removeAll()
        latestDeltas.removeAll()
        trackedKeys.removeAll()
    }
}
