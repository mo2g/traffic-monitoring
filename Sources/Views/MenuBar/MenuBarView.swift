import AppKit
import SwiftUI

// MARK: - 菜单栏标签

/// 菜单栏上常驻显示的上下行速率，上行在上、下行在下。
///
/// 这里给的是一张**自己画好的 NSImage**，而不是 SwiftUI 视图。
/// 原因见 `MenuBarRateImage` 的说明：SwiftUI 会把 label 栅格化并把高度压到
/// 16pt，两行文字放不下，只会显示一行。
@MainActor
struct MenuBarLabel: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector

    var body: some View {
        Image(nsImage: MenuBarRateImage.render(
            upBytesPerSecond: dashboard.totalTxRate,
            downBytesPerSecond: dashboard.totalRxRate,
            fontSize: collector.menuBarFontSize
        ))
    }
}

// MARK: - 菜单栏面板

@MainActor
struct MenuBarPanel: View {
    @Environment(DashboardViewModel.self) private var dashboard
    @Environment(CollectorService.self) private var collector
    @Environment(\.openWindow) private var openWindow

    /// 面板里最多列几个进程。再多就该开主窗口了。
    static let rowCapacity = 6
    /// 单行高度。写死而不是让内容撑开 —— 见 `processList` 的说明。
    static let rowHeight: CGFloat = 18

    /// 面板里只列最活跃的几个
    private var topRows: [ProcessRow] {
        Array(dashboard.rows
            .filter { $0.rxRate + $0.txRate > 0 }
            .sorted { $0.rxRate + $0.txRate > $1.rxRate + $1.txRate }
            .prefix(Self.rowCapacity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actions
            Divider().padding(.vertical, 6)
            totals
            Divider().padding(.vertical, 6)
            processList
        }
        .padding(10)
        .frame(width: 280)
    }

    // MARK: - 进程列表

    /// 放在面板**最底部**，因此可以随内容自由增长。
    ///
    /// 菜单栏面板从菜单栏往下挂，顶边固定、底边浮动 —— 只要可变高度的内容
    /// 位于所有交互元素之下，按钮的屏幕位置就不会动。
    /// 这比「给列表预留固定高度」更好：进程少时不会留一大块空白。
    private var processList: some View {
        VStack(spacing: 0) {
            if topRows.isEmpty {
                Text(L("menubar.noActivity"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.rowHeight)
            } else {
                ForEach(topRows) { processRow($0) }
            }
        }
    }

    private func processRow(_ row: ProcessRow) -> some View {
        HStack(spacing: 6) {
            ProcessIcon(row: row, size: 14)
            Text(row.displayName).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 8)
            Text(ByteFormatter.rateStringCompact(bytesPerSecond: row.rxRate))
                .foregroundStyle(.blue)
            Text(ByteFormatter.rateStringCompact(bytesPerSecond: row.txRate))
                .foregroundStyle(.red)
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(height: Self.rowHeight)
    }

    // MARK: - 汇总

    /// 三个指标**各占固定宽度**，见 `MetricSlot`。
    /// 否则数值一变长度，分隔线和右侧指标就会左右横跳。
    private var totals: some View {
        HStack(spacing: 0) {
            metric(L("summary.downloadRate"),
                   ByteFormatter.rateString(bytesPerSecond: dashboard.totalRxRate),
                   .blue, width: MetricSlot.rate)
            metricDivider
            metric(L("summary.uploadRate"),
                   ByteFormatter.rateString(bytesPerSecond: dashboard.totalTxRate),
                   .red, width: MetricSlot.rate)
            metricDivider
            metric(dashboard.selectedTimeRange.displayName,
                   ByteFormatter.string(bytes: dashboard.totalTraffic),
                   .primary, width: MetricSlot.total)
            Spacer(minLength: 0)
        }
    }

    private var metricDivider: some View {
        Divider().frame(height: 26).padding(.horizontal, MetricSlot.dividerPadding)
    }

    private func metric(_ label: String, _ value: String,
                        _ color: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(width: width, alignment: .leading)
        // 极端数值宁可缩一点也不要把分隔线推走
        .lineLimit(1)
    }

    // MARK: - 操作

    /// 顶部一行紧凑工具栏。
    ///
    /// 三个考虑：
    /// - **位置必须固定**：面板从菜单栏往下挂，顶边固定、底边浮动。
    ///   放在最顶部意味着它的屏幕位置只由面板顶边决定，与下方任何内容无关。
    /// - **不割裂数据**：夹在总计和进程列表中间会把两块数据切开；
    ///   放到最上面，总计与列表就连成一整块。
    /// - **不该喧宾夺主**：开窗口、启停、退出都是低频操作，占三行整宽菜单
    ///   会把真正常看的进程列表挤出视线。压成一行图标 + 短标签即可。
    ///   「退出」单独靠右，与另两个拉开距离，降低误点。
    private var actions: some View {
        HStack(spacing: 4) {
            actionButton(L("menubar.window"), "macwindow") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: MainWindowID.value)
                }
            }
            actionButton(collector.status == .running ? L("toolbar.stop") : L("toolbar.start"),
                         collector.status == .running ? "stop.fill" : "play.fill") {
                if collector.status == .running { collector.stop() }
                else { Task { await collector.start() } }
            }
            Spacer(minLength: 0)
            actionButton(L("menubar.quitShort"), "power") { NSApp.terminate(nil) }
        }
    }

    private func actionButton(_ title: String, _ symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(HoverHighlightButtonStyle())
    }
}


// MARK: - 指标槽位宽度

/// 顶部三个指标各自的固定宽度。
///
/// 数值每秒都在变，字符串长度也跟着变（`0 B/s` ↔ `120.6 KB/s`）。
/// 若让内容决定宽度，分隔线和右侧指标就会左右横跳。
///
/// 与菜单栏图片同样的做法：不手写模板串，直接把一组覆盖各数量级的值喂进
/// **真正的格式化器**量出最大宽度 —— 格式规则将来变了，宽度会自动跟上。
///
/// 按语言缓存：标签是本地化的，换语言后宽度需要重算。
enum MetricSlot {
    /// 指标之间分隔线两侧的留白
    static let dividerPadding: CGFloat = 8

    /// 速率指标（下载 / 上传）
    static var rate: CGFloat { width(kind: .rate) }
    /// 总量指标（今日 / 本周 / 本月）
    static var total: CGFloat { width(kind: .total) }

    /// 三个槽位加两条分隔线的总宽，用来核对能否放进面板
    static var totalRowWidth: CGFloat {
        rate * 2 + total + (dividerPadding * 2 + 1) * 2
    }

    private enum Kind { case rate, total }

    nonisolated(unsafe) private static var cache: [String: CGFloat] = [:]

    private static func width(kind: Kind) -> CGFloat {
        let key = "\(L10n.effective)-\(kind)"
        if let cached = cache[key] { return cached }

        let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 9)
        func measure(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        var widest: CGFloat = 0
        // 速率封顶到 GB/s 量级：再往上（TB/s）现实中不会出现，
        // 为它预留宽度只会白白挤掉别的内容
        let exponents = kind == .rate ? 0...3 : 0...4
        for exponent in exponents {
            for multiplier in [1.0, 9.9, 10.0, 99.0, 999.9] {
                let value = multiplier * pow(1024, Double(exponent))
                let text = kind == .rate
                    ? ByteFormatter.rateString(bytesPerSecond: value)
                    : ByteFormatter.string(bytes: Int64(value))
                widest = max(widest, measure(text, valueFont))
            }
        }

        let labels = kind == .rate
            ? [L("summary.downloadRate"), L("summary.uploadRate")]
            : DashboardViewModel.TimeRange.allCases.map(\.displayName)
        for label in labels { widest = max(widest, measure(label, labelFont)) }

        let result = ceil(widest)
        cache[key] = result
        return result
    }
}

/// 悬停时给一层浅背景，让这些无边框按钮有可点的提示
private struct HoverHighlightButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

/// 主窗口的 scene id，菜单栏面板要用它把窗口叫回来
enum MainWindowID {
    static let value = "main"
}
