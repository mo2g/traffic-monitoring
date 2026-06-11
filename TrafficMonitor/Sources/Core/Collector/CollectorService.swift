import Combine
import Foundation
import UserNotifications

/// 采集服务状态机
///
/// 协调 NettopProcess ↔ TrafficStore（内存缓存）↔ DataStore（批量持久化）。
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
    @Published private(set) var listTick: Int = 0   // 节流后的列表重建信号
    @Published var alertRules: [AlertRule] = []

    private let nettopProcess = NettopProcess()
    private var tickTimer: Timer?
    private var saveTimer: Timer?
    private var previousSnapshot: ProcessSnapshot?
    private var lastSnapshotTime: Date?
    private var isTicking = false
    private var alertThrottle: [String: Date] = [:]
    private let alertThrottleInterval: TimeInterval = 60
    private var lastListTick = Date.distantPast
    private let listTickInterval: TimeInterval = 2.0  // 最多每秒 0.5 次列表重建

    private init() {}

    // MARK: - Public

    func start() async {
        guard status != .running else { return }

        do { try await DataStore.shared.setup() }
        catch {
            await LogStore.shared.log("数据库初始化失败: \(error)", level: .error, tag: "Collector")
            status = .error("Database init failed"); return
        }

        guard let raw = await nettopProcess.takeSnapshot() else {
            await LogStore.shared.log("nettop 不可用", level: .error, tag: "Collector")
            status = .error("nettop 不可用"); return
        }

        let records = NettopParser.parse(raw)
        guard !records.isEmpty else {
            await LogStore.shared.log("nettop 返回空数据", level: .error, tag: "Collector")
            status = .error("netop 无数据"); return
        }

        let snapshot = ProcessAggregator.aggregate(records: records, timestamp: Date())
        let activeDeltas = activeKeysFrom(snapshot)

        // 查询这些活跃进程的历史数据
        let now = Date().timeIntervalSince1970
        let since = now - 86400 // 默认查今天
        let historical = (try? await DataStore.shared.querySummary(since: since, limit: 100)) ?? []

        await TrafficStore.shared.initialize(activeDeltas: activeDeltas, historical: historical)
        await LogStore.shared.log("TrafficStore 已初始化: \(activeDeltas.count) 活跃进程, \(historical.count) 有历史", level: .info, tag: "Collector")

        previousSnapshot = snapshot
        lastSnapshotTime = Date()
        status = .running
        startTimers()
        await LogStore.shared.log("采集已启动 (\(interval)s 采集, \(saveInterval)s 保存)", level: .info, tag: "Collector")
    }

    func stop() {
        tickTimer?.invalidate(); tickTimer = nil
        saveTimer?.invalidate(); saveTimer = nil
        Task {
            await TrafficStore.shared.flushPending()
            await TrafficStore.shared.reset()
        }
        status = .stopped
        Task { await LogStore.shared.log("采集已停止", level: .info, tag: "Collector") }
    }

    func loadAlertRules() { alertRules = AlertStore.shared.load() }

    // MARK: - Private

    private func startTimers() {
        tickTimer?.invalidate(); saveTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { _ in
            Task { await TrafficStore.shared.flushPending() }
        }
        Task { await tick() }
    }

    private func tick() async {
        guard status == .running, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        guard let raw = await nettopProcess.takeSnapshot() else { return }
        let records = NettopParser.parse(raw)
        guard !records.isEmpty else { return }

        let timestamp = Date()
        let snapshot = ProcessAggregator.aggregate(records: records, timestamp: timestamp)
        let intervalTime = lastSnapshotTime.map { timestamp.timeIntervalSince($0) } ?? interval
        let deltas = DeltaCalculator.compute(from: previousSnapshot, to: snapshot, interval: intervalTime)

        // 告警检查
        if !deltas.isEmpty {
            for rule in alertRules where rule.enabled {
                for delta in deltas where rule.isTriggered(by: delta) {
                    let throttleKey = rule.id.uuidString + "_" + delta.identifier.description
                    let now = Date()
                    if let last = alertThrottle[throttleKey], now.timeIntervalSince(last) < alertThrottleInterval { continue }
                    alertThrottle[throttleKey] = now
                    postAlert(rule: rule, delta: delta)
                }
            }
        }

        // 累加到内存缓存
        await TrafficStore.shared.accumulate(deltas: deltas, timestamp: timestamp.timeIntervalSince1970, interval: intervalTime)

        previousSnapshot = snapshot
        lastSnapshotTime = timestamp
        latestDeltas = deltas
        snapshotCount += 1

        // 节流列表重建信号 —— nettop 每次 150-300ms，1s 间隔时避免每 tick 重建
        let now = Date()
        if now.timeIntervalSince(lastListTick) >= listTickInterval {
            lastListTick = now
            listTick &+= 1
        }
    }

    /// 从第一次快照生成伪增量（用于初始化 TrafficStore）
    private func activeKeysFrom(_ snapshot: ProcessSnapshot) -> [ProcessDelta] {
        snapshot.records.map { key, vals in
            ProcessDelta(identifier: key, bytesIn: vals.bytesIn, bytesOut: vals.bytesOut,
                         interval: 1, isEstimated: true)
        }
    }

    // MARK: - Alert

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
