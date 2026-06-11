import Combine
import Foundation
import GRDB

/// 仪表盘 ViewModel
///
/// 按需刷新：
/// - latestDeltas 变化 → 更新速率 + 重建列表（Combine 订阅，仅在有新数据时触发）
/// - 不在无数据时做无用轮询
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var totalRxRate: Double = 0
    @Published var totalTxRate: Double = 0
    @Published var todayTraffic: Int64 = 0
    @Published var processes: [ProcessDisplayItem] = []
    @Published var selectedTimeRange: TimeRange = .today
    @Published var searchText: String = ""
    @Published var isRefreshing = false
    @Published var processGroups: [ProcessGroup] = []
    @Published var isGroupedView: Bool = false
    @Published var groupedProcesses: [GroupDisplayItem] = []

    enum TimeRange: String, CaseIterable, Identifiable {
        case today = "今日", week = "本周", month = "本月"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self { case .today: 86400; case .week: 604800; case .month: 2592000 }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var isStale = false

    func startObserving() {
        let svc = CollectorService.shared

        // 每次有新 delta → 更新实时速率（同步、便宜）
        svc.$latestDeltas
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deltas in
                self?.updateRates(deltas)
            }
            .store(in: &cancellables)

        // listTick 节流变化 → 重建列表（较贵，每 ~2s 一次）
        svc.$listTick
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.rebuildList() }
            }
            .store(in: &cancellables)

        Task {
            await rebuildList()
            updateRates(svc.latestDeltas)
        }
    }

    func stopObserving() {
        cancellables.removeAll()
    }

    func loadGroups() { processGroups = GroupStore.shared.load() }

    // MARK: - Refresh

    /// 同步更新实时速率（纯计算，无 async 调用）
    private func updateRates(_ deltas: [ProcessDelta]) {
        totalRxRate = deltas.reduce(0) { $0 + $1.rxRate }
        totalTxRate = deltas.reduce(0) { $0 + $1.txRate }

        guard !processes.isEmpty else { return }
        var rateMap: [String: (rx: Double, tx: Double)] = [:]
        for d in deltas {
            let k = d.identifier.description
            if let e = rateMap[k] { rateMap[k] = (rx: e.rx + d.rxRate, tx: e.tx + d.txRate) }
            else                  { rateMap[k] = (rx: d.rxRate, tx: d.txRate) }
        }
        for i in processes.indices {
            if let r = rateMap[processes[i].processKey] { processes[i].rxRate = r.rx; processes[i].txRate = r.tx }
            else { processes[i].rxRate = 0; processes[i].txRate = 0 }
        }
    }

    /// delta 到达后：从 TrafficStore 重建列表
    func rebuildList() async {
        guard !isRefreshing else { isStale = true; return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = await TrafficStore.shared.snapshot()

        processes = snapshot.map { kv in
            let s = kv.stats
            return ProcessDisplayItem(
                processKey: kv.key, bundleId: s.bundleId, displayName: s.displayName,
                totalIn: s.totalIn, totalOut: s.totalOut, icon: iconFor(s.displayName),
                rxRate: 0, txRate: 0
            )
        }
        todayTraffic = processes.reduce(0) { $0 + $1.totalBytes }
        updateRates(CollectorService.shared.latestDeltas)

        if isGroupedView {
            var grouped: [UUID: (name: String, in: Int64, out: Int64, count: Int)] = [:]
            var accounted = Set<String>()
            for g in processGroups {
                var gi: Int64 = 0, go: Int64 = 0, c = 0
                for p in processes where g.contains(processKey: p.processKey) {
                    gi += p.totalIn; go += p.totalOut; c += 1; accounted.insert(p.processKey)
                }
                grouped[g.id] = (name: g.name, in: gi, out: go, count: c)
            }
            var items: [GroupDisplayItem] = grouped.map { id, d in
                GroupDisplayItem(id: id, name: d.name, totalIn: d.in, totalOut: d.out, memberCount: d.count)
            }
            let oi = processes.filter { !accounted.contains($0.processKey) }.reduce(0) { $0 + $1.totalIn }
            let oo = processes.filter { !accounted.contains($0.processKey) }.reduce(0) { $0 + $1.totalOut }
            let oc = processes.count - accounted.count
            if oc > 0 { items.append(GroupDisplayItem(id: UUID(), name: "其他", totalIn: oi, totalOut: oo, memberCount: oc)) }
            groupedProcesses = items.sorted { $0.totalBytes > $1.totalBytes }
        }
    }
}

private func iconFor(_ name: String) -> String {
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

// MARK: - Process Display Item

struct ProcessDisplayItem: Identifiable {
    var id: String { processKey }
    let processKey: String
    let bundleId: String?
    let displayName: String
    let totalIn: Int64
    let totalOut: Int64
    let icon: String
    var rxRate: Double = 0
    var txRate: Double = 0
    var totalBytes: Int64 { totalIn + totalOut }

    init(processKey: String, bundleId: String?, displayName: String,
         totalIn: Int64, totalOut: Int64, icon: String,
         rxRate: Double = 0, txRate: Double = 0) {
        self.processKey = processKey; self.bundleId = bundleId; self.displayName = displayName
        self.totalIn = totalIn; self.totalOut = totalOut; self.icon = icon
        self.rxRate = rxRate; self.txRate = txRate
    }
}

// MARK: - Group Display Item

struct GroupDisplayItem: Identifiable {
    var id: UUID
    let name: String
    let totalIn: Int64
    let totalOut: Int64
    let memberCount: Int
    var rxRate: Double = 0
    var txRate: Double = 0
    var totalBytes: Int64 { totalIn + totalOut }
}
