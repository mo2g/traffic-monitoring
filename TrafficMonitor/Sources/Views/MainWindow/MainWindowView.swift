import SwiftUI
import UniformTypeIdentifiers

/// 主窗口：NavigationSplitView 三栏布局
struct MainWindowView: View {
    @EnvironmentObject var collectorService: CollectorService
    @EnvironmentObject var dashboardVM: DashboardViewModel

    @State private var selectedProcessID: String?
    @State private var showingDetail = false
    @State private var showingExport = false

    @State private var sortOrder: [SortDescriptor<RowItem>] = [
        SortDescriptor(\RowItem.totalBytes, order: .reverse)
    ]

    @State private var sortedItems: [RowItem] = []

    /// 每次 process 数据变化时重建 + 应用当前排序
    private func rebuildItems() {
        let items = dashboardVM.processes.map { RowItem(from: $0, grandTotal: dashboardVM.todayTraffic) }
        sortedItems = applySort(items)
    }

    private func applySort(_ items: [RowItem]) -> [RowItem] {
        guard !sortOrder.isEmpty else { return items.sorted { $0.totalBytes > $1.totalBytes } }
        var arr = items
        for desc in sortOrder.reversed() {
            arr.sort(using: desc)
        }
        return arr
    }

    private var selectedProcess: ProcessDisplayItem? {
        dashboardVM.processes.first { $0.processKey == selectedProcessID }
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            VStack(spacing: 0) {
                summaryRow.padding(.horizontal).padding(.top, 12)
                Divider().padding(.top, 12)
                processList
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingDetail, onDismiss: { selectedProcessID = nil }) {
            if let p = selectedProcess {
                DetailWindow(processKey: p.processKey, displayName: p.displayName)
            }
        }
        .fileExporter(
            isPresented: $showingExport,
            document: CSVDocument(processes: sortedItems),
            contentType: .commaSeparatedText,
            defaultFilename: "TrafficMonitor_export.csv"
        ) { _ in }
        .onChange(of: dashboardVM.processes.count) { rebuildItems() }
        .onChange(of: dashboardVM.todayTraffic)   { rebuildItems() }
        .onChange(of: sortOrder)                  { sortedItems = applySort(sortedItems) }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        List {
            Section("时间范围") {
                ForEach(DashboardViewModel.TimeRange.allCases) { range in
                    Label(range.rawValue, systemImage: iconForTimeRange(range))
                        .foregroundColor(dashboardVM.selectedTimeRange == range ? .accentColor : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture { dashboardVM.selectedTimeRange = range }
                }
            }
            Section("视图") {
                Toggle("按分组查看", isOn: $dashboardVM.isGroupedView)
                    .disabled(dashboardVM.processGroups.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "calendar")
                Text("范围: \(dashboardVM.selectedTimeRange.rawValue)")
            }.font(.caption).foregroundColor(.secondary).padding(8)
        }
    }

    // MARK: - Summary

    private var summaryRow: some View {
        HStack(spacing: 12) {
            SummaryCard(title: "下载速率", value: ByteFormatter.rateString(bytesPerSecond: dashboardVM.totalRxRate), icon: "arrow.down")
            SummaryCard(title: "上传速率", value: ByteFormatter.rateString(bytesPerSecond: dashboardVM.totalTxRate), icon: "arrow.up")
            SummaryCard(title: "\(dashboardVM.selectedTimeRange.rawValue)流量", value: ByteFormatter.string(bytes: dashboardVM.todayTraffic), icon: "chart.bar")
        }
    }

    // MARK: - Process Table (原生排序)

    @ViewBuilder
    private var processList: some View {
        if dashboardVM.isGroupedView {
            if dashboardVM.groupedProcesses.isEmpty { emptyView }
            else { groupTableView }
        } else if dashboardVM.processes.isEmpty {
            emptyView
        } else {
            Table(sortedItems, selection: $selectedProcessID, sortOrder: $sortOrder) {
                TableColumn("进程", value: \.displayName) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).frame(width: 18).foregroundColor(.accentColor)
                        Text(item.displayName).lineLimit(1)
                    }
                }
                .width(min: 140)
                TableColumn("实时下载", value: \.rxRate) { item in
                    Text(ByteFormatter.rateString(bytesPerSecond: item.rxRate))
                        .font(.system(size: 12))
                        .foregroundColor(item.rxRate > 0 ? .blue : .secondary)
                        .monospacedDigit()
                }
                .width(min: 85)
                TableColumn("实时上传", value: \.txRate) { item in
                    Text(ByteFormatter.rateString(bytesPerSecond: item.txRate))
                        .font(.system(size: 12))
                        .foregroundColor(item.txRate > 0 ? .red : .secondary)
                        .monospacedDigit()
                }
                .width(min: 85)
                TableColumn("下载", value: \.totalIn) { item in
                    Text(ByteFormatter.string(bytes: item.totalIn))
                        .foregroundColor(.blue).monospacedDigit()
                }
                .width(min: 75)
                TableColumn("上传", value: \.totalOut) { item in
                    Text(ByteFormatter.string(bytes: item.totalOut))
                        .foregroundColor(.red).monospacedDigit()
                }
                .width(min: 75)
                TableColumn("合计", value: \.totalBytes) { item in
                    Text(ByteFormatter.string(bytes: item.totalBytes))
                        .fontWeight(.medium).monospacedDigit()
                }
                .width(min: 75)
                TableColumn("占比") { item in
                    ProgressView(value: item.fractionOfGrandTotal).frame(width: 60)
                }
                .width(min: 60)
            }
            .onChange(of: selectedProcessID) { _, newID in
                guard let id = newID else { return }
                if let item = sortedItems.first(where: { $0.id == id }) {
                    selectedProcessID = item.processKey
                }
                showingDetail = true
            }
            .onAppear { rebuildItems() }
        }
    }

    // MARK: - Group Table

    private var groupTableView: some View {
        Table(dashboardVM.groupedProcesses) {
            TableColumn("分组") { item in
                HStack(spacing: 6) {
                    Image(systemName: item.name == "其他" ? "tray" : "folder")
                        .frame(width: 18).foregroundColor(.accentColor)
                    Text(item.name).lineLimit(1)
                }
            }.width(min: 140)
            TableColumn("实时下载") { item in
                Text(ByteFormatter.rateString(bytesPerSecond: item.rxRate))
                    .font(.system(size: 12))
                    .foregroundColor(item.rxRate > 0 ? .blue : .secondary).monospacedDigit()
            }.width(min: 85)
            TableColumn("实时上传") { item in
                Text(ByteFormatter.rateString(bytesPerSecond: item.txRate))
                    .font(.system(size: 12))
                    .foregroundColor(item.txRate > 0 ? .red : .secondary).monospacedDigit()
            }.width(min: 85)
            TableColumn("下载") { item in
                Text(ByteFormatter.string(bytes: item.totalIn)).foregroundColor(.blue).monospacedDigit()
            }.width(min: 75)
            TableColumn("上传") { item in
                Text(ByteFormatter.string(bytes: item.totalOut)).foregroundColor(.red).monospacedDigit()
            }.width(min: 75)
            TableColumn("合计") { item in
                Text(ByteFormatter.string(bytes: item.totalBytes)).fontWeight(.medium).monospacedDigit()
            }.width(min: 75)
            TableColumn("进程数") { item in Text("\(item.memberCount)").monospacedDigit() }.width(min: 50)
            TableColumn("占比") { item in
                ProgressView(
                    value: Double(item.totalBytes),
                    total: Double(max(dashboardVM.groupedProcesses.map(\.totalBytes).reduce(0, +), 1))
                ).frame(width: 60)
            }.width(min: 60)
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            if collectorService.status == .running {
                Image(systemName: "network").font(.system(size: 36)).foregroundColor(.secondary)
                Text("等待网络活动...").foregroundColor(.secondary)
            } else {
                Image(systemName: "play.circle").font(.system(size: 36)).foregroundColor(.accentColor)
                Text("按 ⌘⏎ 启动采集").foregroundColor(.secondary)
                if case .error(let msg) = collectorService.status {
                    Text(msg).font(.caption).foregroundColor(.red).padding(.top, 4)
                }
            }
            Spacer()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusLabel).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())

            if collectorService.status == .running {
                Button(action: { collectorService.stop() }) {
                    Label("停止", systemImage: "stop.fill")
                }.help("停止采集")
            } else {
                Button(action: { Task { await collectorService.start() } }) {
                    Label("启动", systemImage: "play.fill")
                }.help("启动采集").keyboardShortcut(.return, modifiers: [])
            }

            Spacer()

            if !dashboardVM.processes.isEmpty {
                Button(action: { showingExport = true }) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }.help("导出 CSV")
            }

            if collectorService.status == .running {
                Text("快照 #\(collectorService.snapshotCount)")
                    .foregroundColor(.secondary).font(.caption.monospacedDigit())
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch collectorService.status {
        case .idle, .stopped: .gray; case .running: .green; case .error: .red
        }
    }

    private var statusLabel: String {
        switch collectorService.status {
        case .idle: "就绪"; case .running: "采集中"; case .stopped: "已停止"
        case .error(let msg): msg
        }
    }

    private func iconForTimeRange(_ range: DashboardViewModel.TimeRange) -> String {
        switch range { case .today: "clock"; case .week: "calendar"; case .month: "calendar.badge.clock" }
    }
}

// MARK: - NSObject Row Item (enables native Table sorting)

final class RowItem: NSObject, Identifiable {
    var id: String { processKey }
    let processKey: String
    @objc dynamic var displayName: String
    @objc dynamic var icon: String
    @objc dynamic var rxRate: Double
    @objc dynamic var txRate: Double
    @objc dynamic var totalIn: Int64
    @objc dynamic var totalOut: Int64
    @objc dynamic var totalBytes: Int64
    @objc dynamic var fractionOfGrandTotal: Double

    init(from p: ProcessDisplayItem, grandTotal: Int64) {
        processKey = p.processKey
        displayName = p.displayName
        icon = p.icon
        rxRate = p.rxRate
        txRate = p.txRate
        totalIn = p.totalIn
        totalOut = p.totalOut
        totalBytes = p.totalBytes
        fractionOfGrandTotal = grandTotal > 0 ? Double(p.totalBytes) / Double(grandTotal) : 0
        super.init()
    }
}

// MARK: - CSV Export Document

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let csv: String

    init(processes: [RowItem]) {
        var lines = ["进程,实时下载(B/s),实时上传(B/s),下载(B),上传(B),合计(B)"]
        for p in processes {
            lines.append("\"\(p.displayName)\",\(Int(p.rxRate)),\(Int(p.txRate)),\(p.totalIn),\(p.totalOut),\(p.totalBytes)")
        }
        csv = lines.joined(separator: "\n")
    }

    init(configuration: ReadConfiguration) throws {
        csv = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: csv.data(using: .utf8)!)
    }
}
