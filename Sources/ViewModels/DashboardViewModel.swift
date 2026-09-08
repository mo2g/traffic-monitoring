import AppKit
import Foundation

/// 仪表盘 ViewModel
///
/// 只做一件事：接住管线推来的 `DashboardSnapshot`，摊成视图直接可用的属性。
/// 所有聚合计算都发生在 `TrafficPipeline` actor 上，这里不做重活。
///
/// 用 `@Observable` 而非 `ObservableObject`，SwiftUI 按**属性**粒度追踪依赖：
/// 速率数字每秒变化只会让 3 张汇总卡片失效，不会把整个 `NavigationSplitView`
/// 连同表格一起推倒重排（那正是重构前 72% CPU 的来源）。
///
/// 每次赋值前都比一次相等：没变就不写，也就不会触发任何重绘。
@Observable
@MainActor
final class DashboardViewModel {
    /// 应用级唯一实例。菜单栏和主窗口共用同一份状态。
    static let shared = DashboardViewModel()

    // MARK: 视图数据

    private(set) var rows: [ProcessRow] = []
    private(set) var groupRows: [GroupRow] = []
    private(set) var totalRxRate: Double = 0
    private(set) var totalTxRate: Double = 0
    private(set) var totalTraffic: Int64 = 0

    // MARK: 视图状态

    var sortOrder: [KeyPathComparator<ProcessRow>] = [
        KeyPathComparator(\ProcessRow.totalBytes, order: .reverse)
    ] {
        didSet { resort() }
    }

    /// 统计窗口。切换会真正重查数据库并替换管线里的「历史」部分。
    var selectedTimeRange: TimeRange = Preferences.timeRange {
        didSet {
            guard selectedTimeRange != oldValue else { return }
            Preferences.timeRange = selectedTimeRange
            Task { await CollectorService.shared.applyTimeRange(selectedTimeRange) }
        }
    }

    /// 进程名过滤（工具栏搜索框）
    var searchText: String = "" {
        didSet { guard searchText != oldValue else { return }; resort() }
    }
    var isGroupedView = false {
        didSet { rebuildGroups() }
    }
    var processGroups: [ProcessGroup] = [] {
        didSet { rebuildGroups() }
    }

    /// 最近一次快照（未排序原始行），排序/分组变化时据此重算
    @ObservationIgnored private var latest = DashboardSnapshot()

    enum TimeRange: String, CaseIterable, Identifiable {
        // rawValue 是持久化标识，必须与界面语言无关；展示名走 `displayName`
        case today, week, month

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .today: L("range.today")
            case .week:  L("range.week")
            case .month: L("range.month")
            }
        }

        /// 窗口起点。用日历边界而不是「往前推 N 秒」——
        /// 标签写着「今日」，用户期望的是今天零点起算，不是过去 24 小时。
        var start: Date {
            let calendar = Calendar.current
            let now = Date()
            let component: Set<Calendar.Component> = switch self {
            case .today: [.year, .month, .day]
            case .week:  [.yearForWeekOfYear, .weekOfYear]
            case .month: [.year, .month]
            }
            return calendar.date(from: calendar.dateComponents(component, from: now)) ?? now
        }
    }

    // MARK: - 订阅

    /// 建立对采集快照的订阅。
    ///
    /// 这件事的生命周期跟着**应用**，不跟着窗口。之前放在主窗口的
    /// `onAppear`/`onDisappear` 里，关掉窗口就把 sink 置空，菜单栏的数字
    /// 随即冻住 —— 而菜单栏模式的整个意义就是没有窗口时也能看。
    ///
    /// 真正该省的开销由管线侧的可见性闸门负责（`setUIVisible`），
    /// 那里能区分「窗口被遮挡」和「菜单栏还需要数据」。
    func startObserving() {
        CollectorService.shared.snapshotSink = { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    func loadGroups() { processGroups = GroupStore.shared.load() }

    // MARK: - 快照落地

    func apply(_ snapshot: DashboardSnapshot) {
        latest = snapshot

        if totalRxRate != snapshot.totalRxRate { totalRxRate = snapshot.totalRxRate }
        if totalTxRate != snapshot.totalTxRate { totalTxRate = snapshot.totalTxRate }
        if totalTraffic != snapshot.totalBytes { totalTraffic = snapshot.totalBytes }

        let sorted = sortedRows(snapshot.rows)
        if rows != sorted { rows = sorted }

        rebuildGroups()
    }

    // MARK: - 排序 / 分组

    private func resort() {
        let sorted = sortedRows(latest.rows)
        if rows != sorted { rows = sorted }
    }

    private func sortedRows(_ source: [ProcessRow]) -> [ProcessRow] {
        var rows = source
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            rows = rows.filter { $0.displayName.localizedCaseInsensitiveContains(needle) }
        }
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }

    private func rebuildGroups() {
        guard isGroupedView else {
            if !groupRows.isEmpty { groupRows = [] }
            return
        }
        var items: [GroupRow] = []
        var accounted = Set<String>()

        for g in processGroups {
            var totalIn: Int64 = 0, totalOut: Int64 = 0
            var rx = 0.0, tx = 0.0, count = 0
            for r in latest.rows where g.contains(processKey: r.key) {
                totalIn += r.totalIn; totalOut += r.totalOut
                rx += r.rxRate; tx += r.txRate
                count += 1
                accounted.insert(r.key)
            }
            items.append(GroupRow(id: g.id, name: g.name, isOthers: false,
                                  totalIn: totalIn, totalOut: totalOut,
                                  rxRate: rx, txRate: tx, memberCount: count))
        }

        let others = latest.rows.filter { !accounted.contains($0.key) }
        if !others.isEmpty {
            items.append(GroupRow(
                id: Self.othersGroupID,
                name: L("group.others"),
                isOthers: true,
                totalIn: others.reduce(0) { $0 + $1.totalIn },
                totalOut: others.reduce(0) { $0 + $1.totalOut },
                rxRate: others.reduce(0) { $0 + $1.rxRate },
                txRate: others.reduce(0) { $0 + $1.txRate },
                memberCount: others.count
            ))
        }

        items.sort { $0.totalBytes > $1.totalBytes }
        if groupRows != items { groupRows = items }
    }

    /// 「其他」分组用固定 ID，否则每次重建都是新身份，列表会整体重绘
    private static let othersGroupID = UUID()
}
