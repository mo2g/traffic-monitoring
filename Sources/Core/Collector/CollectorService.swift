import AppKit
import Foundation

// MARK: - 采集状态

enum CollectorStatus: Equatable {
    case idle
    case running
    case stopped
    case error(String)
}

/// 采集服务：进程生命周期 + 帧消费循环 + UI 可见性
///
/// ```
/// NStatCollector ──AsyncStream(bufferingNewest 1)──▶ TrafficPipeline (actor)
///                                                         │ 节流后
///                                                         ▼
///                                                    snapshotSink → MainActor
/// ```
///
/// 这个类型本身只持有**状态**，不做任何逐帧计算 —— 计算全部在 `TrafficPipeline`
/// 上。同时它用 `@Observable` 而不是 `ObservableObject`：后者的 `objectWillChange`
/// 是对象级通知，一个内部计数器自增就会让所有观察它的视图整树重排。
@Observable
@MainActor
final class CollectorService {
    static let shared = CollectorService()

    private(set) var status: CollectorStatus = .idle

    /// 采集间隔（秒）。写入即落 UserDefaults —— 此前只存在内存里，重启就回默认值。
    var interval: TimeInterval = Preferences.interval {
        didSet { Preferences.interval = interval }
    }

    /// 落库间隔（秒），同样持久化
    var saveInterval: TimeInterval = Preferences.saveInterval {
        didSet { Preferences.saveInterval = saveInterval }
    }

    var alertRules: [AlertRule] = []

    /// 菜单栏常驻显示实时速率
    ///
    /// 开启时 UI 可见性闸门必须一直放行 —— 否则主窗口被遮挡后管线停止产出快照，
    /// 菜单栏的数字会冻在最后一帧。
    var menuBarEnabled: Bool = Preferences.menuBarEnabled {
        didSet {
            Preferences.menuBarEnabled = menuBarEnabled
            syncVisibility()
        }
    }

    /// UI 快照出口，由 `DashboardViewModel` 注册
    @ObservationIgnored
    var snapshotSink: (@MainActor (DashboardSnapshot) -> Void)?

    @ObservationIgnored private var collector: NStatCollector?
    @ObservationIgnored private var collectionTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var visibilityObservers: [NSObjectProtocol] = []
    /// 上一次 stop() 的收尾任务，start() 会先等它完成再初始化，
    /// 否则「改设置 → 重启采集」时 reset 可能落在 initialize 之后，把历史累计抹掉
    @ObservationIgnored private var teardownTask: Task<Void, Never>?

    private init() {}

    // MARK: - 生命周期

    func start() async {
        guard status != .running else { return }
        await teardownTask?.value
        teardownTask = nil

        do {
            try await DataStore.shared.setup()
            try await DataStore.shared.pruneExpired()
        } catch {
            await LogStore.shared.log("DB 初始化失败: \(error)", level: .error, tag: "Collector")
            status = .error("Database init failed")
            return
        }

        guard let collector = NStatCollector() else {
            await LogStore.shared.log("NetworkStatistics 框架不可用", level: .error, tag: "Collector")
            status = .error("NetworkStatistics unavailable")
            return
        }
        self.collector = collector

        // 历史累计先灌进管线，再开始消费实时帧
        await TrafficPipeline.shared.setExcludedProcesses(
            Preferences.parseExcluded(Preferences.excludedProcessesText))
        await applyTimeRange(Preferences.timeRange)
        await TrafficPipeline.shared.setAlertRules(alertRules)

        // 单次迭代：首帧由管线自己识别为 baseline，无需在这里先消费一帧
        let stream = collector.start(interval: interval)
        runCollectionLoop(stream)
        startSaveLoop()
        startVisibilityMonitoring()

        status = .running
        await LogStore.shared.log(
            "采集已启动（\(interval)s 采样 / \(Constants.uiRefreshInterval)s 刷新 / \(saveInterval)s 落库）",
            level: .info, tag: "Collector"
        )
    }

    func stop() {
        status = .stopped
        collectionTask?.cancel()
        collectionTask = nil
        saveTask?.cancel()
        saveTask = nil
        stopVisibilityMonitoring()
        collector?.stop()
        collector = nil
        teardownTask = Task {
            await TrafficPipeline.shared.flush(force: true)
            await TrafficPipeline.shared.reset()
            await LogStore.shared.log("采集已停止", level: .info, tag: "Collector")
        }
    }

    /// 改设置后重启采集（保证停止先彻底收尾）
    func restart() async {
        stop()
        await start()
    }

    /// 切换统计窗口：按新窗口重查数据库，替换管线里的历史部分。
    ///
    /// 实时累计（尚未落库的那部分）保持不动 —— 它和历史部分不重叠，
    /// `flush()` 会把它转进历史。
    func applyTimeRange(_ range: DashboardViewModel.TimeRange) async {
        let since = range.start.timeIntervalSince1970
        let summaries = (try? await DataStore.shared.querySummary(since: since)) ?? []
        await TrafficPipeline.shared.reloadHistorical(summaries)
        await LogStore.shared.log(
            "统计窗口切换为「\(range.rawValue)」，载入 \(summaries.count) 条历史",
            level: .info, tag: "Collector"
        )
    }

    /// 应用「排除进程」列表：立即生效，已累计的数据一并清出
    func applyExcludedProcesses(_ text: String) {
        Preferences.excludedProcessesText = text
        let names = Preferences.parseExcluded(text)
        Task { await TrafficPipeline.shared.setExcludedProcesses(names) }
    }

    func loadAlertRules() {
        alertRules = AlertStore.shared.load()
        let rules = alertRules
        Task { await TrafficPipeline.shared.setAlertRules(rules) }
    }

    func applyAlertRules(_ rules: [AlertRule]) {
        alertRules = rules
        Task { await TrafficPipeline.shared.setAlertRules(rules) }
    }

    // MARK: - 消费循环

    private func runCollectionLoop(_ stream: AsyncStream<TrafficFrame>) {
        collectionTask = Task.detached(priority: .utility) { [weak self] in
            for await frame in stream {
                if Task.isCancelled { break }
                // 一帧只进一次 actor；不到刷新节拍或窗口不可见时返回 nil，
                // 主线程完全不被唤醒
                guard let snapshot = await TrafficPipeline.shared.ingest(frame) else { continue }
                await MainActor.run { [weak self] in
                    self?.snapshotSink?(snapshot)
                }
            }
        }
    }

    private func startSaveLoop() {
        let seconds = saveInterval
        saveTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { break }
                await TrafficPipeline.shared.flush()
            }
        }
    }

    // MARK: - 窗口可见性

    /// 窗口被完全遮挡 / 应用被隐藏时停止生成 UI 快照（采集与落库继续）
    private func startVisibilityMonitoring() {
        guard visibilityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        visibilityObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CollectorService.shared.syncVisibility() }
            }
        }
        syncVisibility()
    }

    private func stopVisibilityMonitoring() {
        visibilityObservers.forEach(NotificationCenter.default.removeObserver)
        visibilityObservers.removeAll()
        Task { await TrafficPipeline.shared.setUIVisible(true) }
    }

    private func syncVisibility() {
        guard !menuBarEnabled else {
            // 菜单栏在显示实时速率，快照不能停
            Task { await TrafficPipeline.shared.setUIVisible(true) }
            return
        }
        let windows = NSApp.windows.filter { $0.isVisible }
        // 一个可见窗口都没有时也当作可见，避免启动早期误判导致首屏空白
        let visible = windows.isEmpty || windows.contains { $0.occlusionState.contains(.visible) }
        Task { await TrafficPipeline.shared.setUIVisible(visible) }
    }
}

// MARK: - 偏好持久化

/// 采集相关偏好的读写。
///
/// 单独抽出来是为了让 `CollectorService` 的属性 `didSet` 保持一行，
/// 同时把 UserDefaults 的 key 集中在一处。
enum Preferences {
    private static let intervalKey = "com.trafficmonitor.interval"
    private static let saveIntervalKey = "com.trafficmonitor.saveInterval"
    private static let menuBarKey = "com.trafficmonitor.menuBarEnabled"
    private static let timeRangeKey = "com.trafficmonitor.timeRange"
    private static let excludedKey = "com.trafficmonitor.excludedProcesses"

    static var interval: TimeInterval {
        get { read(intervalKey, default: Constants.defaultInterval) }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    static var saveInterval: TimeInterval {
        get { read(saveIntervalKey, default: Constants.batchSaveInterval) }
        set { UserDefaults.standard.set(newValue, forKey: saveIntervalKey) }
    }

    static var timeRange: DashboardViewModel.TimeRange {
        get {
            guard let raw = UserDefaults.standard.string(forKey: timeRangeKey) else { return .today }
            return DashboardViewModel.TimeRange(rawValue: raw) ?? .today
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: timeRangeKey) }
    }

    /// 用户手动排除的进程名（原样保存，便于回显到输入框）
    static var excludedProcessesText: String {
        get { UserDefaults.standard.string(forKey: excludedKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: excludedKey) }
    }

    /// 解析成用于比对的小写集合
    static func parseExcluded(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    static var menuBarEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: menuBarKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: menuBarKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: menuBarKey) }
    }

    /// UserDefaults 对「键不存在」和「值为 0」都返回 0，这里区分开
    private static func read(_ key: String, default fallback: TimeInterval) -> TimeInterval {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : fallback
    }
}
