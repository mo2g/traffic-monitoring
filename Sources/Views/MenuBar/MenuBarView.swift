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
    private static let rowCapacity = 6
    /// 单行高度。写死而不是让内容撑开 —— 见 `processList` 的说明。
    private static let rowHeight: CGFloat = 18

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
            processList
            Divider().padding(.vertical, 6)
            actions
        }
        .padding(10)
        .frame(width: 280)
    }

    // MARK: - 进程列表

    /// 高度**恒定**，不随活跃进程数量伸缩。
    ///
    /// 活跃进程每秒都在变。如果让列表撑开面板，下面的「打开主窗口 / 启停采集 /
    /// 退出」就会跟着上下跳 —— 用户正要点「打开主窗口」，面板一缩，
    /// 手指落到了「退出」。所以始终按 `rowCapacity` 行预留空间，不足的补空行。
    private var processList: some View {
        VStack(spacing: 0) {
            ForEach(0..<Self.rowCapacity, id: \.self) { index in
                if index < topRows.count {
                    processRow(topRows[index])
                } else {
                    Color.clear.frame(height: Self.rowHeight)
                }
            }
        }
        .frame(height: CGFloat(Self.rowCapacity) * Self.rowHeight)
        .overlay {
            if topRows.isEmpty {
                Text(L("menubar.noActivity"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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

    private var actions: some View {
        VStack(spacing: 2) {
            menuButton(L("menubar.openMainWindow"), "macwindow") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: MainWindowID.value)
                }
            }
            menuButton(collector.status == .running ? L("menubar.stopCollecting")
                                                    : L("menubar.startCollecting"),
                       collector.status == .running ? "stop.fill" : "play.fill") {
                if collector.status == .running { collector.stop() }
                else { Task { await collector.start() } }
            }
            Divider().padding(.vertical, 2)
            menuButton(L("menubar.quit"), "power") { NSApp.terminate(nil) }
        }
    }

    private func menuButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 14)
                Text(title).font(.system(size: 11))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 主窗口的 scene id，菜单栏面板要用它把窗口叫回来
enum MainWindowID {
    static let value = "main"
}
