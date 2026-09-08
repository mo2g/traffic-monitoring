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
            totals
            Divider().padding(.vertical, 6)
            actions
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

    private var totals: some View {
        HStack(spacing: 0) {
            metric(L("summary.downloadRate"),
                   ByteFormatter.rateString(bytesPerSecond: dashboard.totalRxRate), .blue)
            Divider().frame(height: 26).padding(.horizontal, 10)
            metric(L("summary.uploadRate"),
                   ByteFormatter.rateString(bytesPerSecond: dashboard.totalTxRate), .red)
            Divider().frame(height: 26).padding(.horizontal, 10)
            metric(dashboard.selectedTimeRange.displayName,
                   ByteFormatter.string(bytes: dashboard.totalTraffic), .primary)
            Spacer()
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                // 数值宽度变化不该推动旁边的分隔线
                .monospacedDigit()
        }
    }

    // MARK: - 操作

    /// 紧凑的一行工具栏，而不是三条整宽菜单项。
    ///
    /// 两个考虑：
    /// - **位置必须固定**：面板从菜单栏往下挂，顶边固定、底边浮动。
    ///   把所有交互元素放在可变高度的进程列表**之上**，按钮就永远不会移位。
    ///   （实测：空面板与满面板的顶部 241 行像素完全一致。）
    /// - **不该喧宾夺主**：开窗口、启停、退出都是低频操作，占三行整宽菜单
    ///   会把真正常看的进程列表挤到视线之外。压成一行图标+短标签即可。
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
