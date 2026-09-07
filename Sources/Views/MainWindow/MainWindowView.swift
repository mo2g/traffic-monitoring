import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口：NavigationSplitView 三栏布局
///
/// 拆分原则：**每个子视图只读它真正需要的属性**。
/// `@Observable` 按属性追踪依赖，因此速率每秒变化只会让 `SummaryRow` 失效，
/// 表格行变化只会让 `ProcessTableView` 失效，外层的 NavigationSplitView /
/// 侧栏 / 工具栏都不会重新求值 —— 也就不会再触发那条 30 层深的
/// `-[NSView _layoutSubtreeWithOldSize:]` 递归。
@MainActor
struct MainWindowView: View {
    @Environment(CollectorService.self) private var collector
    @Environment(DashboardViewModel.self) private var dashboard

    @State private var selectedProcessKey: String?
    @State private var detailTarget: ProcessRow?
    @State private var exportDocument: CSVDocument?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            VStack(spacing: 0) {
                SummaryRow().padding(.horizontal).padding(.top, 12)
                Divider().padding(.top, 12)
                ContentTable(selection: $selectedProcessKey, onOpenDetail: { detailTarget = $0 })
            }
        }
        .toolbar { toolbarContent }
        .sheet(item: $detailTarget, onDismiss: { selectedProcessKey = nil }) { row in
            DetailWindow(row: row)
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil },
                                 set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "TrafficMonitor_export.csv"
        ) { _ in exportDocument = nil }

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

            if collector.status == .running {
                Button { collector.stop() } label: {
                    Label("停止", systemImage: "stop.fill")
                }.help("停止采集")
            } else {
                Button { Task { await collector.start() } } label: {
                    Label("启动", systemImage: "play.fill")
                }
                .help("启动采集")
                .keyboardShortcut(.return, modifiers: [])
            }

            Spacer()

            searchField

            Button { exportDocument = CSVDocument(rows: dashboard.rows) } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }.help("导出 CSV")
        }
    }

    /// 自己拼一个搜索框，而不是用 `.searchable(placement: .toolbar)`。
    ///
    /// 后者会插入 `NSSearchToolbarItemView`，而它的 `updateConstraints` 内部又去调
    /// `animateToolbarUpdates → layoutSubtreeIfNeeded`，在约束更新过程中重入布局，
    /// AppKit 会打印
    /// "It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out"。
    /// 用栈定位到 `-[NSSearchToolbarItemView _updateMinWidthConstraints:]` 后换成普通 TextField。
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("搜索进程", text: Bindable(dashboard).searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 130)
            if !dashboard.searchText.isEmpty {
                Button { dashboard.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
        .frame(width: 190, alignment: .leading)
    }

    private var statusColor: Color {
        switch collector.status {
        case .idle, .stopped: .gray
        case .running: .green
        case .error: .red
        }
    }

    private var statusLabel: String {
        switch collector.status {
        case .idle: "就绪"
        case .running: "采集中"
        case .stopped: "已停止"
        case .error(let msg): msg
        }
    }
}

// MARK: - 侧栏

@MainActor
private struct SidebarView: View {
    @Environment(DashboardViewModel.self) private var dashboard

    var body: some View {
        @Bindable var dashboard = dashboard
        // 这里刻意**不用** `Section`。
        //
        // macOS 上带 Section 的 List 会落到 NSOutlineView，构建时要 expandItem:
        // 展开每个 section，而 AppKit 在这条路径上会自我重入：
        //   expandItem: → NSTableRowData.endUpdates → _keepTopRowStableAtLeastOnce
        //     → rowAtPoint: → _cacheRowSpansInRange:        ← 第一次进入
        //       → _adjustRowSpansStartingAtRow: → _updateTableViewSize
        //         → _minimumFrameSize → _totalHeightOfTableView
        //           → _cacheRowSpansInRange:                ← 重入
        // 于是每次启动都会打印
        // "Application performed a reentrant operation in its NSTableView delegate"
        // （AppKit 声明将来会升级成 assert）。
        //
        // 扁平 List 走的是 NSTableView，没有 expandItem: 这一步，警告消失，
        // 同时完整保留原生侧栏的材质、行距与滚动行为。
        List {
            sectionHeader("时间范围")
            ForEach(DashboardViewModel.TimeRange.allCases) { range in
                Label(range.rawValue, systemImage: icon(for: range))
                    .foregroundColor(dashboard.selectedTimeRange == range ? .accentColor : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture { dashboard.selectedTimeRange = range }
            }

            sectionHeader("视图")
            Toggle("按分组查看", isOn: $dashboard.isGroupedView)
                .disabled(dashboard.processGroups.isEmpty)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "calendar")
                Text("范围: \(dashboard.selectedTimeRange.rawValue)")
            }
            .font(.caption).foregroundColor(.secondary).padding(8)
        }
    }

    /// 复刻 Section header 的视觉，但不引入 NSOutlineView
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    private func icon(for range: DashboardViewModel.TimeRange) -> String {
        switch range {
        case .today: "clock"
        case .week: "calendar"
        case .month: "calendar.badge.clock"
        }
    }
}

// MARK: - 汇总卡片（每秒更新，只有这三张卡失效）

@MainActor
private struct SummaryRow: View {
    @Environment(DashboardViewModel.self) private var dashboard

    var body: some View {
        HStack(spacing: 12) {
            SummaryCard(title: "下载速率",
                        value: ByteFormatter.rateString(bytesPerSecond: dashboard.totalRxRate),
                        icon: "arrow.down")
            SummaryCard(title: "上传速率",
                        value: ByteFormatter.rateString(bytesPerSecond: dashboard.totalTxRate),
                        icon: "arrow.up")
            SummaryCard(title: "\(dashboard.selectedTimeRange.rawValue)流量",
                        value: ByteFormatter.string(bytes: dashboard.totalTraffic),
                        icon: "chart.bar")
        }
    }
}

// MARK: - 表格容器（只读 isGroupedView）

@MainActor
private struct ContentTable: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector
    @Binding var selection: String?
    let onOpenDetail: (ProcessRow) -> Void

    /// 关闭时把列宽和标题都压成空，让这一列实际上消失。
    ///
    /// 本来该用 `@TableColumnBuilder` 的条件列直接不声明它，但 `buildIf`
    /// 要求 macOS 14.4+，而本项目部署目标是 14.0 —— 为一个装饰性的列抬高
    /// 系统要求不划算。
    private var sparklineWidth: CGFloat { collector.sparklineEnabled ? 70 : 0 }

    var body: some View {
        if dashboard.isGroupedView {
            GroupTableView()
        } else {
            ProcessTableView(selection: $selection, onOpenDetail: onOpenDetail)
        }
    }
}

// MARK: - 进程表

@MainActor
private struct ProcessTableView: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector
    @Binding var selection: String?
    let onOpenDetail: (ProcessRow) -> Void

    /// 关闭时把列宽和标题都压成空，让这一列实际上消失。
    ///
    /// 本来该用 `@TableColumnBuilder` 的条件列直接不声明它，但 `buildIf`
    /// 要求 macOS 14.4+，而本项目部署目标是 14.0 —— 为一个装饰性的列抬高
    /// 系统要求不划算。
    private var sparklineWidth: CGFloat { collector.sparklineEnabled ? 70 : 0 }

    var body: some View {
        @Bindable var dashboard = dashboard
        if dashboard.rows.isEmpty {
            EmptyStateView()
        } else {
            Table(dashboard.rows, selection: $selection, sortOrder: $dashboard.sortOrder) {
                TableColumn("进程", value: \.displayName) { row in
                    HStack(spacing: 6) {
                        ProcessIcon(row: row)
                        Text(row.displayName).lineLimit(1)
                    }
                }
                .width(min: 140)

                TableColumn("实时下载", value: \.rxRate) { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.rxRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.rxRate > 0 ? .blue : .secondary)
                        .monospacedDigit()
                }
                .width(min: 85)

                TableColumn("实时上传", value: \.txRate) { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.txRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.txRate > 0 ? .red : .secondary)
                        .monospacedDigit()
                }
                .width(min: 85)

                TableColumn("下载", value: \.totalIn) { row in
                    Text(ByteFormatter.string(bytes: row.totalIn))
                        .foregroundColor(.blue).monospacedDigit()
                }
                .width(min: 75)

                TableColumn("上传", value: \.totalOut) { row in
                    Text(ByteFormatter.string(bytes: row.totalOut))
                        .foregroundColor(.red).monospacedDigit()
                }
                .width(min: 75)

                TableColumn("合计", value: \.totalBytes) { row in
                    Text(ByteFormatter.string(bytes: row.totalBytes))
                        .fontWeight(.medium).monospacedDigit()
                }
                .width(min: 90)

                TableColumn(collector.sparklineEnabled ? "趋势" : "") { row in
                    if collector.sparklineEnabled {
                        Sparkline(values: row.spark)
                    }
                }
                .width(min: 0, ideal: sparklineWidth, max: sparklineWidth)
            }
            // primaryAction 即双击。此前是「单击即弹模态框」，导致想排序或选行
            // 都会被详情窗打断。
            .contextMenu(forSelectionType: ProcessRow.ID.self) { keys in
                if let row = row(for: keys) { menu(for: row) }
            } primaryAction: { keys in
                if let row = row(for: keys) { onOpenDetail(row) }
            }
        }
    }

    private func row(for keys: Set<ProcessRow.ID>) -> ProcessRow? {
        guard let key = keys.first else { return nil }
        return dashboard.rows.first { $0.key == key }
    }

    @ViewBuilder
    private func menu(for row: ProcessRow) -> some View {
        Button("查看时间线") { onOpenDetail(row) }
        Divider()
        Button("复制名称") { copy(row.displayName) }
        if let bundleId = row.bundleId {
            Button("复制 Bundle ID") { copy(bundleId) }
        }
        if let path = row.iconPath, FileManager.default.fileExists(atPath: path) {
            Divider()
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 分组表

@MainActor
private struct GroupTableView: View {
    @Environment(DashboardViewModel.self) private var dashboard

    var body: some View {
        if dashboard.groupRows.isEmpty {
            EmptyStateView()
        } else {
            Table(dashboard.groupRows) {
                TableColumn("分组") { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.name == "其他" ? "tray" : "folder")
                            .frame(width: 18).foregroundColor(.accentColor)
                        Text(row.name).lineLimit(1)
                    }
                }.width(min: 140)

                TableColumn("实时下载") { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.rxRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.rxRate > 0 ? .blue : .secondary).monospacedDigit()
                }.width(min: 85)

                TableColumn("实时上传") { row in
                    Text(ByteFormatter.rateString(bytesPerSecond: row.txRate))
                        .font(.system(size: 12))
                        .foregroundColor(row.txRate > 0 ? .red : .secondary).monospacedDigit()
                }.width(min: 85)

                TableColumn("下载") { row in
                    Text(ByteFormatter.string(bytes: row.totalIn)).foregroundColor(.blue).monospacedDigit()
                }.width(min: 75)

                TableColumn("上传") { row in
                    Text(ByteFormatter.string(bytes: row.totalOut)).foregroundColor(.red).monospacedDigit()
                }.width(min: 75)

                TableColumn("合计") { row in
                    Text(ByteFormatter.string(bytes: row.totalBytes)).fontWeight(.medium).monospacedDigit()
                }.width(min: 75)

                TableColumn("进程数") { row in
                    Text("\(row.memberCount)").monospacedDigit()
                }.width(min: 50)
            }
        }
    }
}

// MARK: - 空态

@MainActor
private struct EmptyStateView: View {
    @Environment(CollectorService.self) private var collector

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if collector.status == .running {
                Image(systemName: "network").font(.system(size: 36)).foregroundColor(.secondary)
                Text("等待网络活动...").foregroundColor(.secondary)
            } else {
                Image(systemName: "play.circle").font(.system(size: 36)).foregroundColor(.accentColor)
                Text("按 ⏎ 启动采集").foregroundColor(.secondary)
                if case .error(let msg) = collector.status {
                    Text(msg).font(.caption).foregroundColor(.red).padding(.top, 4)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - CSV 导出

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let csv: String

    init(rows: [ProcessRow]) {
        var lines = ["进程,实时下载(B/s),实时上传(B/s),下载(B),上传(B),合计(B)"]
        for r in rows {
            lines.append("\"\(r.displayName)\",\(Int(r.rxRate)),\(Int(r.txRate)),\(r.totalIn),\(r.totalOut),\(r.totalBytes)")
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
