import AppKit
import SwiftUI
import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - 菜单栏面板布局
// ============================================================

/// 面板从菜单栏往下挂：**顶边固定、底边浮动**。
/// 因此只要可变高度的进程列表位于所有交互元素之下，按钮就不会移位。
///
/// 这组测试把面板真正渲染成位图来验证，而不是只看代码里写没写 `.frame`。
@MainActor
final class MenuBarPanelLayoutTests: XCTestCase {
    private func row(_ index: Int) -> ProcessRow {
        ProcessRow(key: "p\(index)", bundleId: nil,
                   displayName: "进程 \(index)",
                   icon: "app.dashed", iconPath: nil,
                   totalIn: 1_000, totalOut: 500,
                   rxRate: Double(90_000 >> index), txRate: 500, spark: [])
    }

    private func hosting(processCount: Int) -> NSHostingView<some View> {
        let dashboard = DashboardViewModel.shared
        dashboard.apply(DashboardSnapshot(
            rows: (0..<processCount).map(row),
            totalRxRate: 123_456, totalTxRate: 45_678, totalBytes: 10_900_000_000
        ))
        let host = NSHostingView(rootView:
            MenuBarPanel().environment(dashboard).environment(CollectorService.shared))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func height(_ processCount: Int) -> CGFloat {
        hosting(processCount: processCount).fittingSize.height
    }

    private func bitmap(_ processCount: Int) -> NSBitmapImageRep {
        let host = hosting(processCount: processCount)
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两张位图从第几**点**开始出现差异
    private func firstDifferingRow(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGFloat {
        let scale = CGFloat(a.pixelsWide) / a.size.width
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                return CGFloat(y) / scale
            }
        }
        return CGFloat(min(a.pixelsHigh, b.pixelsHigh)) / scale
    }

    /// 核心断言：面板顶部的固定区必须完整包住三个操作按钮。
    ///
    /// 总计区约 40pt + 分隔线 + 操作行约 26pt ≈ 88pt。阈值取 80pt：
    /// 一旦有人把操作行挪回进程列表**下面**，逐像素一致的前缀会缩到只剩
    /// 总计区（约 40pt），这条就会失败。
    func testFixedRegionCoversActionRow() {
        let identical = firstDifferingRow(bitmap(0), bitmap(MenuBarPanel.rowCapacity))
        XCTAssertGreaterThanOrEqual(identical, 80,
            "顶部固定区只有 \(identical)pt，装不下操作行 —— 按钮会随进程数移位")
    }

    /// 进程数变化只应改变列表区，固定区一像素都不该动
    func testFixedRegionIdenticalAcrossEveryProcessCount() {
        let reference = bitmap(0)
        for count in [1, 2, 3, MenuBarPanel.rowCapacity] {
            let identical = firstDifferingRow(reference, bitmap(count))
            XCTAssertGreaterThanOrEqual(identical, 80, "\(count) 个进程时固定区发生了变化")
        }
    }

    /// 列表向下生长：每多一个进程，面板正好高一行
    func testPanelGrowsByExactlyOneRowPerProcess() {
        // 0 个进程时列表位置放的是「无网络活动」提示，同样占一行
        let base = height(1)
        for count in 2...MenuBarPanel.rowCapacity {
            XCTAssertEqual(height(count), base + CGFloat(count - 1) * MenuBarPanel.rowHeight,
                           accuracy: 0.5, "\(count) 个进程时高度不符合逐行增长")
        }
    }

    /// 超出容量的进程被截断，面板不会无限变长
    func testExcessProcessesAreTruncated() {
        XCTAssertEqual(height(MenuBarPanel.rowCapacity), height(50))
    }

    /// 宽度固定 —— 进程名长短不该改变面板宽度
    func testWidthIsFixed() {
        let dashboard = DashboardViewModel.shared
        func width(_ name: String) -> CGFloat {
            dashboard.apply(DashboardSnapshot(rows: [
                ProcessRow(key: "a", bundleId: nil, displayName: name, icon: "app.dashed",
                           iconPath: nil, totalIn: 1, totalOut: 1, rxRate: 1, txRate: 1, spark: [])
            ]))
            return NSHostingView(rootView: MenuBarPanel()
                .environment(dashboard).environment(CollectorService.shared)).fittingSize.width
        }
        XCTAssertEqual(width("a"), width(String(repeating: "很长的进程名", count: 10)))
    }
}
