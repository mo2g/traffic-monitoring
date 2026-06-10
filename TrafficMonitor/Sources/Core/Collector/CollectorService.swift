import Combine
import Foundation

/// 采集服务状态机
///
/// 协调 RootCollector（osascript + nettop） ↔ DataStore（持久化存储），
/// 提供 Combine Publisher 供 ViewModel 订阅。
///
/// 状态流转:
/// ```
///   idle → authorizing → running → stopped
///     │                        │
///     └──── error ←───────────┘
/// ```
@MainActor
final class CollectorService: ObservableObject {
    static let shared = CollectorService()

    @Published private(set) var status: CollectorStatus = .idle
    @Published var interval: TimeInterval = Constants.defaultInterval
    @Published private(set) var latestDeltas: [ProcessDelta] = []
    @Published private(set) var snapshotCount: Int = 0

    private let rootCollector = RootCollector()
    private var timer: Timer?
    private var previousSnapshot: ProcessSnapshot?
    private var lastSnapshotTime: Date?
    private var isTicking = false

    private init() {}

    // MARK: - Public API

    /// 启动采集（首次调用弹出系统密码对话框）
    func start() async {
        guard status != .running else { return }

        do {
            try await DataStore.shared.setup()
        } catch {
            status = .error("Database init failed: \(error.localizedDescription)")
            return
        }

        let ok = await rootCollector.authorizeAndStart()
        guard ok else {
            status = await rootCollector.status
            return
        }

        status = .running
        previousSnapshot = nil
        startTimer()
    }

    /// 停止采集
    func stop() {
        timer?.invalidate()
        timer = nil
        Task {
            await rootCollector.shutdown()
            await MainActor.run {
                if case .stopped = status {} else {
                    status = .stopped
                }
            }
        }
    }

    // MARK: - Private

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        Task { await tick() }
    }

    private func tick() async {
        guard status == .running, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        // 1. 通过 osascript 获取 nettop 原始输出
        guard let raw = await rootCollector.takeSnapshot() else {
            let currentStatus = await rootCollector.status
            if case .error = currentStatus {
                status = currentStatus
            }
            return
        }

        // 2. 解析
        let records = NettopParser.parse(raw)
        guard !records.isEmpty else { return }

        // 3. 聚合
        let timestamp = Date()
        let snapshot = ProcessAggregator.aggregate(records: records, timestamp: timestamp)

        // 4. 计算差值
        let intervalTime = lastSnapshotTime.map { timestamp.timeIntervalSince($0) } ?? interval
        let deltas = DeltaCalculator.compute(
            from: previousSnapshot,
            to: snapshot,
            interval: intervalTime
        )

        // 5. 持久化
        if !deltas.isEmpty {
            let events = deltas.map { delta in
                TrafficEvent(
                    id: nil,
                    timestamp: timestamp.timeIntervalSince1970,
                    interval: intervalTime,
                    processKey: delta.identifier.description,
                    bundleId: delta.identifier.bundleId,
                    displayName: delta.identifier.displayName,
                    bytesIn: delta.bytesIn,
                    bytesOut: delta.bytesOut
                )
            }

            do {
                try await DataStore.shared.insertEvents(events)
            } catch {
                print("[CollectorService] DB write error: \(error)")
            }
        }

        // 6. 更新状态
        previousSnapshot = snapshot
        lastSnapshotTime = timestamp
        latestDeltas = deltas
        snapshotCount += 1
    }
}
