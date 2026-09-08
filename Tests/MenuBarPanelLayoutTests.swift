import AppKit
import SwiftUI
import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - 菜单栏面板布局
// ============================================================

/// 面板里的进程列表每秒都在变。如果它撑开面板高度，下面的
/// 「打开主窗口 / 启停采集 / 退出」就会跟着上下跳 —— 用户正要点
/// 「打开主窗口」，面板一缩，手指落到「退出」上。
///
/// 这组测试把面板真正渲染出来量高度，而不是只看代码里写没写 `.frame`。
@MainActor
final class MenuBarPanelLayoutTests: XCTestCase {
    private func row(_ index: Int) -> ProcessRow {
        ProcessRow(key: "p\(index)", bundleId: nil,
                   displayName: "进程名字长度也会变化 \(index)",
                   icon: "app.dashed", iconPath: nil,
                   totalIn: 1_000, totalOut: 500,
                   rxRate: 1_000 + Double(index), txRate: 500, spark: [])
    }

    private func panelHeight(processCount: Int) -> CGFloat {
        let dashboard = DashboardViewModel.shared
        dashboard.apply(DashboardSnapshot(
            rows: (0..<processCount).map(row),
            totalRxRate: 1_234, totalTxRate: 567, totalBytes: 9_876_543
        ))
        let host = NSHostingView(rootView:
            MenuBarPanel()
                .environment(dashboard)
                .environment(CollectorService.shared)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// 核心断言：0 个到超出容量的进程，面板高度必须完全一致
    func testHeightIsIndependentOfProcessCount() {
        let heights = [0, 1, 3, 6, 12].map { panelHeight(processCount: $0) }
        XCTAssertEqual(Set(heights).count, 1,
                       "面板高度随进程数变化，底部菜单会移位: \(heights)")
    }

    /// 空列表时显示的提示文字也不能撑高面板
    func testEmptyStateDoesNotChangeHeight() {
        XCTAssertEqual(panelHeight(processCount: 0), panelHeight(processCount: 6))
    }

    /// 超出容量的进程被截断，而不是把面板越撑越长
    func testExcessProcessesAreTruncated() {
        XCTAssertEqual(panelHeight(processCount: 6), panelHeight(processCount: 50))
    }

    /// 宽度同样固定 —— 进程名长短不该改变面板宽度
    func testWidthIsFixed() {
        let narrow = { () -> CGFloat in
            let d = DashboardViewModel.shared
            d.apply(DashboardSnapshot(rows: [
                ProcessRow(key: "a", bundleId: nil, displayName: "a", icon: "app.dashed",
                           iconPath: nil, totalIn: 1, totalOut: 1, rxRate: 1, txRate: 1, spark: [])
            ]))
            let host = NSHostingView(rootView: MenuBarPanel()
                .environment(d).environment(CollectorService.shared))
            return host.fittingSize.width
        }()
        let wide = { () -> CGFloat in
            let d = DashboardViewModel.shared
            d.apply(DashboardSnapshot(rows: [
                ProcessRow(key: "b", bundleId: nil,
                           displayName: String(repeating: "很长的进程名", count: 10),
                           icon: "app.dashed", iconPath: nil,
                           totalIn: 1, totalOut: 1, rxRate: 1, txRate: 1, spark: [])
            ]))
            let host = NSHostingView(rootView: MenuBarPanel()
                .environment(d).environment(CollectorService.shared))
            return host.fittingSize.width
        }()
        XCTAssertEqual(narrow, wide, "进程名长度改变了面板宽度")
    }
}
