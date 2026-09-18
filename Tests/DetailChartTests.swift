import AppKit
import SwiftUI
import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - 时间线分段（断开空洞）
// ============================================================

/// 两次突发之间整段时间没有数据时，线段必须断开 ——
/// 07:58 与 14:08 连成一条斜线会让人以为这六小时一直在传。
final class TimelineSegmentTests: XCTestCase {
    private func point(_ t: TimeInterval, bytes: Int64 = 1_000) -> TimelinePoint {
        TimelinePoint(timestamp: t, bytesIn: bytes, bytesOut: 0)
    }

    func testContiguousBucketsStayInOneSegment() {
        XCTAssertEqual(TimelineBucket.segmentIndices([point(0), point(60), point(120)], bucket: 60),
                       [0, 0, 0])
    }

    func testMissingBucketStartsNewSegment() {
        // 缺了 120 那一分钟 → 后面的点另起一段
        XCTAssertEqual(TimelineBucket.segmentIndices([point(0), point(60), point(180)], bucket: 60),
                       [0, 0, 1])
    }

    func testSixHourGapIsABreak() {
        XCTAssertEqual(TimelineBucket.segmentIndices([point(0), point(6 * 3_600)], bucket: 60),
                       [0, 1])
        XCTAssertEqual(TimelineBucket.segmentIndices([], bucket: 60), [])
    }
}

// ============================================================
// MARK: - 图表渲染：空洞不连线
// ============================================================

@MainActor
final class DetailChartGapTests: XCTestCase {
    private func render(_ points: [TimelinePoint], range: TimeInterval = 86_400) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: TrafficChart(points: points, style: .line, range: range)
            .frame(width: 800, height: 320))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 320)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 不透明（alpha > 0.5）的系列色像素计数；x 区间按位图宽度取比例。
    /// 网格线是同色但只有 ~6% 不透明度，靠 alpha 区分。
    private func markPixels(_ rep: NSBitmapImageRep, xFrom: Double, xTo: Double,
                            isMark: (NSColor) -> Bool) -> Int {
        var count = 0
        for x in Int(Double(rep.pixelsWide) * xFrom) ..< Int(Double(rep.pixelsWide) * xTo) {
            for y in 0 ..< rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5 else { continue }
                if isMark(color) { count += 1 }
            }
        }
        return count
    }

    private func bluePixels(_ rep: NSBitmapImageRep, xFrom: Double, xTo: Double) -> Int {
        markPixels(rep, xFrom: xFrom, xTo: xTo) {
            $0.blueComponent > 0.55 && $0.blueComponent - $0.redComponent > 0.25
        }
    }

    private func redPixels(_ rep: NSBitmapImageRep, xFrom: Double, xTo: Double) -> Int {
        markPixels(rep, xFrom: xFrom, xTo: xTo) {
            $0.redComponent > 0.55 && $0.redComponent - $0.blueComponent > 0.25
        }
    }

    /// **回归**：两个点相隔 12 小时、中间没有任何数据，不能连成线。
    /// 只测分段函数不够 —— 这里把图真的渲染成位图数像素。
    func testGapIsNotConnected() {
        let now = Date()
        let points = [
            TimelinePoint(timestamp: now.addingTimeInterval(-18 * 3_600).timeIntervalSince1970,
                          bytesIn: 2_000_000, bytesOut: 0),
            TimelinePoint(timestamp: now.addingTimeInterval(-6 * 3_600).timeIntervalSince1970,
                          bytesIn: 2_000_000, bytesOut: 0),
        ]
        let rep = render(points)
        // 两个孤点各自要画出来（否则「中间没有线」是假通过），
        // 且下载/上传两个方向都要在（上传孤点曾经落回系统强调色变成蓝点）
        XCTAssertGreaterThan(bluePixels(rep, xFrom: 0.20, xTo: 0.34), 0, "左端点应该画出来")
        XCTAssertGreaterThan(bluePixels(rep, xFrom: 0.66, xTo: 0.80), 0, "右端点应该画出来")
        XCTAssertGreaterThan(redPixels(rep, xFrom: 0.20, xTo: 0.34), 0, "左端点应该有上传方向的点")
        XCTAssertGreaterThan(redPixels(rep, xFrom: 0.66, xTo: 0.80), 0, "右端点应该有上传方向的点")
        // 中间不能有任何东西把两端连起来
        XCTAssertEqual(bluePixels(rep, xFrom: 0.45, xTo: 0.55), 0, "空洞不能被连成线")
        XCTAssertEqual(redPixels(rep, xFrom: 0.45, xTo: 0.55), 0, "上行也不能跨空洞连线")
    }
}
