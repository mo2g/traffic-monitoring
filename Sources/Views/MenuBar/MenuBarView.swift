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

    /// 面板里只列最活跃的几个，再多就该开主窗口了
    private var topRows: [ProcessRow] {
        Array(dashboard.rows
            .filter { $0.rxRate + $0.txRate > 0 }
            .sorted { $0.rxRate + $0.txRate > $1.rxRate + $1.txRate }
            .prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            totals
            Divider().padding(.vertical, 6)

            if topRows.isEmpty {
                Text(L("menubar.noActivity"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(topRows) { row in
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
                    .padding(.vertical, 2)
                }
            }

            Divider().padding(.vertical, 6)
            actions
        }
        .padding(10)
        .frame(width: 280)
    }

    private var totals: some View {
        HStack(spacing: 0) {
            metric(L("summary.downloadRate"), ByteFormatter.rateString(bytesPerSecond: dashboard.totalRxRate), .blue)
            Divider().frame(height: 26).padding(.horizontal, 10)
            metric(L("summary.uploadRate"), ByteFormatter.rateString(bytesPerSecond: dashboard.totalTxRate), .red)
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
        }
    }

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
            menuButton(collector.status == .running ? L("menubar.stopCollecting") : L("menubar.startCollecting"),
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
