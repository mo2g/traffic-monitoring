import Combine
import Foundation
import UserNotifications

/// 采集服务
///
/// NettopDaemon (持久进程 + AsyncStream 队列) ↔ TrafficStore (内存缓存) ↔ DataStore (批量持久化)
///
/// ```
///   idle → running → stopped
///     │                │
///     └─── error ←────┘
/// ```
@MainActor
final class CollectorService: ObservableObject {
    static let shared = CollectorService()

    @Published private(set) var status: CollectorStatus = .idle
    @Published var interval: TimeInterval = Constants.defaultInterval
    @Published var saveInterval: TimeInterval = Constants.batchSaveInterval
    @Published private(set) var latestDeltas: [ProcessDelta] = []
    @Published private(set) var snapshotCount: Int = 0
    @Published private(set) var listTick: Int = 0
    @Published var alertRules: [AlertRule] = []

    private let daemon = NettopDaemon()
    private var collectionTask: Task<Void, Never>?
    private var saveTimer: Timer?
    private var previousRecords: [ProcessRecord]?
    private var lastSnapshotTime: Date?
    private var knownPIDs: Set<Int32> = []
    private var alertThrottle: [String: Date] = [:]
    private let alertThrottleInterval: TimeInterval = 60
    private var lastListTick = Date.distantPast
    private let listTickInterval: TimeInterval = 1.5

    private init() {}

    // MARK: - Public

    func start() async {
        guard status != .running else { return }

        do { try await DataStore.shared.setup() }
        catch {
            await LogStore.shared.log("DB 初始化失败: \(error)", level: .error, tag: "Collector")
            status = .error("Database init failed"); return
        }

        // 启动持久 nettop 守护进程 → AsyncStream, timer 按 interval 取快照
        let stream = await daemon.start(minInterval: interval)
        await LogStore.shared.log("nettop daemon 已启动", level: .info, tag: "Collector")

        // 等第一张快照到达 (用于初始化 TrafficStore)
        var initialRaw: String? = nil
        for await (raw, _) in stream {
            initialRaw = raw
            break
        }
        guard let raw = initialRaw else {
            await LogStore.shared.log("nettop daemon 无数据", level: .error, tag: "Collector")
            await daemon.stop(); status = .error("netop 无数据"); return
        }

        let records = NettopParser.parse(raw)
        guard !records.isEmpty else {
            await LogStore.shared.log("nettop 返回空数据", level: .error, tag: "Collector")
            await daemon.stop(); status = .error("netop 无数据"); return
        }

        let activeDeltas = activeKeysFrom(records)

        let now = Date().timeIntervalSince1970
        let since = now - 86400
        let historical = (try? await DataStore.shared.querySummary(since: since, limit: 100)) ?? []

        await TrafficStore.shared.initialize(activeDeltas: activeDeltas, historical: historical)
        await LogStore.shared.log("TrafficStore: \(activeDeltas.count) active, \(historical.count) historical", level: .info, tag: "Collector")

        previousRecords = records
        lastSnapshotTime = Date()
        knownPIDs = Set(records.map(\.pid))
        status = .running

        // 启动消费循环 (迭代 stream 剩余部分)
        runCollectionLoop(stream)

        // 启动批量保存 timer
        startSaveTimer()
        await LogStore.shared.log("采集已启动 (\(interval)s tick, \(saveInterval)s 保存)", level: .info, tag: "Collector")
    }

    func stop() {
        Task {
            await daemon.stop()
            await TrafficStore.shared.flushPending()
            await TrafficStore.shared.reset()
        }
        status = .stopped
        Task { await LogStore.shared.log("采集已停止", level: .info, tag: "Collector") }
    }

    func loadAlertRules() { alertRules = AlertStore.shared.load() }

    // MARK: - Collection Loop

    private func runCollectionLoop(_ stream: AsyncStream<(String, Date)>) {
        collectionTask = Task { [weak self] in
            for await (raw, ts) in stream {
                guard let self, status == .running else { break }
                await self.processSnapshot(raw, timestamp: ts)
            }
        }
    }

    private func processSnapshot(_ raw: String, timestamp: Date) async {
        let records = NettopParser.parse(raw)
        guard !records.isEmpty else { return }

        let intervalTime = lastSnapshotTime.map { timestamp.timeIntervalSince($0) } ?? interval

        // 先在 PID 级别计算增量，再按 Bundle ID 聚合
        // 这避免了 PID 退出导致聚合累计值回退 → /10 估算 → 速率虚高的问题
        // knownPIDs 用于区分「真正的新进程」和「上次快照遗漏的老进程」
        let pidDeltas = DeltaCalculator.compute(
            from: previousRecords, to: records,
            interval: intervalTime, knownPIDs: knownPIDs
        )
        let deltas = ProcessAggregator.aggregateDeltas(pidDeltas)

        // 告警检查
        if !deltas.isEmpty {
            for rule in alertRules where rule.enabled {
                for delta in deltas where rule.isTriggered(by: delta) {
                    let key = rule.id.uuidString + "_" + delta.identifier.description
                    let now = Date()
                    if let last = alertThrottle[key], now.timeIntervalSince(last) < alertThrottleInterval { continue }
                    alertThrottle[key] = now
                    postAlert(rule: rule, delta: delta)
                }
            }
        }

        // 累加到内存缓存
        await TrafficStore.shared.accumulate(deltas: deltas, timestamp: timestamp.timeIntervalSince1970, interval: intervalTime)

        previousRecords = records
        lastSnapshotTime = timestamp
        knownPIDs.formUnion(records.map(\.pid))
        latestDeltas = deltas
        snapshotCount += 1

        // 节流列表重建
        let now = Date()
        if now.timeIntervalSince(lastListTick) >= listTickInterval {
            lastListTick = now
            listTick &+= 1
        }
    }

    // MARK: - Save Timer

    private func startSaveTimer() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { _ in
            Task { await TrafficStore.shared.flushPending() }
        }
    }

    // MARK: - Helpers

    private func activeKeysFrom(_ records: [ProcessRecord]) -> [ProcessDelta] {
        // 将首次快照的 record 转为 PIDDelta → 按 BundleID 聚合为 ProcessDelta
        let pidDeltas: [PIDDelta] = records.compactMap { r in
            guard r.bytesIn > 0 || r.bytesOut > 0 else { return nil }
            return PIDDelta(pid: r.pid, execName: r.execName,
                            bytesIn: r.bytesIn, bytesOut: r.bytesOut,
                            interval: 1, isEstimated: true)
        }
        return ProcessAggregator.aggregateDeltas(pidDeltas)
    }

    private func postAlert(rule: AlertRule, delta: ProcessDelta) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let body: String
        if let tb = rule.thresholdBytes {
            body = "\(delta.identifier.displayName) 流量 \(ByteFormatter.string(bytes: delta.totalBytes)) 超过 \(ByteFormatter.string(bytes: tb))"
        } else if let tr = rule.thresholdRate {
            body = "\(delta.identifier.displayName) 速率 \(ByteFormatter.rateString(bytesPerSecond: delta.totalRate)) 超过 \(ByteFormatter.rateString(bytesPerSecond: tr))"
        } else { return }

        let c = UNMutableNotificationContent(); c.title = "TrafficMonitor 告警"; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
