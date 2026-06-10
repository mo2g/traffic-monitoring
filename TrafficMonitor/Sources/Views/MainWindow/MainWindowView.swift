import SwiftUI
import UniformTypeIdentifiers

/// 主窗口：NavigationSplitView 三栏布局
struct MainWindowView: View {
    @EnvironmentObject var collectorService: CollectorService
    @EnvironmentObject var dashboardVM: DashboardViewModel

    @State private var selectedProcessID: String?
    @State private var showingDetail = false
    @State private var showingExport = false

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
        .sheet(isPresented: $showingDetail) {
            if let p = selectedProcess {
                DetailWindow(processKey: p.processKey, displayName: p.displayName)
            }
        }
        .fileExporter(
            isPresented: $showingExport,
            document: CSVDocument(processes: dashboardVM.processes),
            contentType: .commaSeparatedText,
            defaultFilename: "TrafficMonitor_export.csv"
        ) { _ in }
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

    // MARK: - Process List

    @ViewBuilder
    private var processList: some View {
        if dashboardVM.processes.isEmpty {
            emptyView
        } else {
            Table(dashboardVM.processes, selection: $selectedProcessID) {
                TableColumn("进程") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).frame(width: 18).foregroundColor(.accentColor)
                        Text(item.displayName).lineLimit(1)
                    }
                }
                .width(min: 150)

                TableColumn("下载") { item in
                    Text(ByteFormatter.string(bytes: item.totalIn)).foregroundColor(.blue).monospacedDigit()
                }
                .width(min: 80)

                TableColumn("上传") { item in
                    Text(ByteFormatter.string(bytes: item.totalOut)).foregroundColor(.red).monospacedDigit()
                }
                .width(min: 80)

                TableColumn("合计") { item in
                    Text(ByteFormatter.string(bytes: item.totalBytes)).fontWeight(.medium).monospacedDigit()
                }
                .width(min: 80)

                TableColumn("占比") { item in
                    ProgressView(value: item.fraction(of: dashboardVM.todayTraffic)).frame(width: 80)
                }
                .width(min: 60)
            }
            .onChange(of: selectedProcessID) { oldID, newID in
                if newID != nil { showingDetail = true }
            }
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            if collectorService.status == .running {
                Image(systemName: "network").font(.system(size: 36)).foregroundColor(.secondary)
                Text("等待网络活动...").foregroundColor(.secondary)
            } else if case .authorizing = collectorService.status {
                ProgressView()
                Text("正在请求授权...").foregroundColor(.secondary)
            } else {
                Image(systemName: "play.circle").font(.system(size: 36)).foregroundColor(.accentColor)
                Text("按 ⌘⏎ 启动采集").foregroundColor(.secondary)
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
        case .idle, .stopped: .gray; case .authorizing: .orange; case .running: .green; case .error: .red
        }
    }

    private var statusLabel: String {
        switch collectorService.status {
        case .idle: "就绪"; case .authorizing: "授权中"; case .running: "采集中"; case .stopped: "已停止"; case .error: "错误"
        }
    }

    private func iconForTimeRange(_ range: DashboardViewModel.TimeRange) -> String {
        switch range { case .today: "clock"; case .week: "calendar"; case .month: "calendar.badge.clock" }
    }
}

// MARK: - CSV Export Document

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let csv: String

    init(processes: [ProcessDisplayItem]) {
        var lines = ["进程,下载(B),上传(B),合计(B)"]
        for p in processes {
            lines.append("\"\(p.displayName)\",\(p.totalIn),\(p.totalOut),\(p.totalBytes)")
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
