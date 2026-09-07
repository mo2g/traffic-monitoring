import AppKit
import SwiftUI

// MARK: - 菜单栏标签

/// 菜单栏上常驻显示的上下行速率。
///
/// 两个约束决定了这里的写法：
///
/// 1. **宽度必须恒定**。标签每秒刷新，只要渲染宽度会变，NSStatusItem 就要在
///    布局过程中重新测量，AppKit 会打印
///    "It's not legal to call -layoutSubtreeIfNeeded on a view which is already
///    being laid out"，同时整条菜单栏跟着左右抖动。
///    所以用等宽字体 + 定长格式串 + 显式 frame 三重保证。
/// 2. 上下两行比左右并排省一半横向空间，也是同类工具的通行做法。
@MainActor
struct MenuBarLabel: View {
    @Environment(DashboardViewModel.self) private var dashboard

    var body: some View {
        VStack(alignment: .trailing, spacing: -1) {
            Text("↓" + ByteFormatter.rateStringCompact(bytesPerSecond: dashboard.totalRxRate))
            Text("↑" + ByteFormatter.rateStringCompact(bytesPerSecond: dashboard.totalTxRate))
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .frame(width: 46, alignment: .trailing)
        .fixedSize()
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
                Text("当前没有网络活动")
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
            metric("下载", ByteFormatter.rateString(bytesPerSecond: dashboard.totalRxRate), .blue)
            Divider().frame(height: 26).padding(.horizontal, 10)
            metric("上传", ByteFormatter.rateString(bytesPerSecond: dashboard.totalTxRate), .red)
            Divider().frame(height: 26).padding(.horizontal, 10)
            metric(dashboard.selectedTimeRange.rawValue,
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
            menuButton("打开主窗口", "macwindow") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: MainWindowID.value)
                }
            }
            menuButton(collector.status == .running ? "停止采集" : "启动采集",
                       collector.status == .running ? "stop.fill" : "play.fill") {
                if collector.status == .running { collector.stop() }
                else { Task { await collector.start() } }
            }
            Divider().padding(.vertical, 2)
            menuButton("退出 TrafficMonitor", "power") { NSApp.terminate(nil) }
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
