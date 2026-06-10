import Combine
import Foundation
import GRDB

extension Notification.Name {
    static let dashboardRefresh = Notification.Name("com.trafficmonitor.dashboardRefresh")
}

/// 仪表盘 ViewModel
///
/// 从 CollectorService 的 @Published 属性和 DataStore 获取数据，
/// 聚合出 UI 所需的展示字段。
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var totalRxRate: Double = 0
    @Published var totalTxRate: Double = 0
    @Published var todayTraffic: Int64 = 0
    @Published var processes: [ProcessDisplayItem] = []
    @Published var selectedTimeRange: TimeRange = .today
    @Published var searchText: String = ""
    @Published var isRefreshing = false

    enum TimeRange: String, CaseIterable, Identifiable {
        case today = "今日"
        case week = "本周"
        case month = "本月"

        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .today: return 86400
            case .week:  return 604800
            case .month: return 2592000
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    func startObserving() {
        // 每秒刷新一次实时数据
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // 不在 Sendable 闭包中捕获 self，改用 NotificationCenter
            NotificationCenter.default.post(name: .dashboardRefresh, object: nil)
        }

        // 监听刷新通知
        NotificationCenter.default.publisher(for: .dashboardRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    func stopObserving() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let service = CollectorService.shared

        // 实时速率：从最新增量计算
        let latest = service.latestDeltas
        totalRxRate = latest.reduce(0) { $0 + $1.rxRate }
        totalTxRate = latest.reduce(0) { $0 + $1.txRate }

        // 历史数据：从 SQLite 查询
        let now = Date().timeIntervalSince1970
        let since = now - selectedTimeRange.seconds

        do {
            let summaries = try await DataStore.shared.querySummary(since: since, limit: 50)

            let filtered = searchText.isEmpty
                ? summaries
                : summaries.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }

            processes = filtered.map { ProcessDisplayItem(from: $0) }
            todayTraffic = summaries.reduce(0) { $0 + $1.totalBytes }
        } catch {
            // DB 查询失败时保持上次数据
        }
    }
}

// MARK: - Process Display Item

struct ProcessDisplayItem: Identifiable {
    var id: String { processKey }
    let processKey: String
    let bundleId: String?
    let displayName: String
    let totalIn: Int64
    let totalOut: Int64
    let icon: String

    var totalBytes: Int64 { totalIn + totalOut }

    init(from summary: ProcessSummary) {
        self.processKey = summary.processKey
        self.bundleId = summary.bundleId
        self.displayName = summary.displayName
        self.totalIn = summary.totalIn
        self.totalOut = summary.totalOut
        // 从进程名推断图标
        self.icon = Self.iconForProcess(summary.displayName)
    }

    /// 占比（0.0-1.0）
    func fraction(of grandTotal: Int64) -> Double {
        guard grandTotal > 0 else { return 0 }
        return Double(totalBytes) / Double(grandTotal)
    }

    private static func iconForProcess(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("chrome")  { return "globe" }
        if lower.contains("edge")    { return "globe" }
        if lower.contains("safari")  { return "safari" }
        if lower.contains("firefox") { return "flame" }
        if lower.contains("code")    { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("wechat")  { return "message" }
        if lower.contains("telegram") { return "paperplane" }
        if lower.contains("slack")   { return "number" }
        if lower.contains("discord") { return "headphones" }
        if lower.contains("zoom")    { return "video" }
        if lower.contains("spotify") { return "music.note" }
        if lower.contains("mail")    { return "envelope" }
        if lower.contains("terminal") || lower.contains("iterm") { return "terminal" }
        if lower.contains("shadowrocket") || lower.contains("surge") || lower.contains("clash") {
            return "arrow.triangle.swap"
        }
        return "app.dashed"
    }
}
