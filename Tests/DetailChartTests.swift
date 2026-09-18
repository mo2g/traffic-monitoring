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
    private func render(_ points: [TimelinePoint], style: ChartStyle = .line,
                        range: TimeInterval = 86_400,
                        mirrorsUpload: Bool = true) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: TrafficChart(points: points, style: style, range: range,
                                                        mirrorsUpload: mirrorsUpload)
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

    /// 匹配像素所在的行（去重、升序）。用来判断两个方向的填充各占了哪一段
    private func markRows(_ rep: NSBitmapImageRep, xFrom: Double, xTo: Double,
                          minAlpha: Double, isMark: (NSColor) -> Bool) -> [Int] {
        var rows: Set<Int> = []
        for x in Int(Double(rep.pixelsWide) * xFrom) ..< Int(Double(rep.pixelsWide) * xTo) {
            for y in 0 ..< rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > minAlpha else { continue }
                if isMark(color) { rows.insert(y) }
            }
        }
        return rows.sorted()
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

    private func fills(_ rep: NSBitmapImageRep) -> (blue: [Int], red: [Int]) {
        let blue = markRows(rep, xFrom: 0.24, xTo: 0.30, minAlpha: 0.15) {
            $0.blueComponent > 0.55 && $0.blueComponent - $0.redComponent > 0.25
        }
        let red = markRows(rep, xFrom: 0.24, xTo: 0.30, minAlpha: 0.15) {
            $0.redComponent > 0.55 && $0.redComponent - $0.blueComponent > 0.25
        }
        return (blue, red)
    }

    /// **默认布局（同轴）**：两个方向都画在零轴上方 —— 上行不能跑到轴下方。
    func testUploadStaysAboveTheAxisByDefault() {
        let t0 = Date().addingTimeInterval(-18 * 3_600).timeIntervalSince1970
        let points = [
            TimelinePoint(timestamp: t0, bytesIn: 4_000_000, bytesOut: 1_000_000),
            TimelinePoint(timestamp: t0 + 300, bytesIn: 4_000_000, bytesOut: 1_000_000),
        ]
        let rep = render(points, style: .area, mirrorsUpload: false)
        let (blue, red) = fills(rep)
        XCTAssertFalse(blue.isEmpty, "下载应该画出来")
        XCTAssertFalse(red.isEmpty, "上传应该画出来")
        XCTAssertLessThanOrEqual(red.max() ?? 0, (blue.max() ?? 0) + 3,
                                 "同轴模式下上行也在零轴上方（基线一致），不会伸到轴下")
        XCTAssertLessThan(blue.min() ?? 0, red.min() ?? 0, "上传更小，顶点应低于下载顶点")
    }

    /// **镜像布局（可选）**：上行镜像到零轴下方。面积、柱状都要 ——
    /// 旧实现两个方向都填在轴上方：面积混成紫色，柱状叠成一根（高度是两者之和）。
    func testUploadIsMirroredBelowTheAxis() {
        for style in [ChartStyle.area, .bar] {
            assertUploadIsBelowTheAxis(style)
        }
    }

    private func assertUploadIsBelowTheAxis(_ style: ChartStyle) {
        let t0 = Date().addingTimeInterval(-18 * 3_600).timeIntervalSince1970   // 24h 窗口的 25% 处
        let points = [
            TimelinePoint(timestamp: t0, bytesIn: 4_000_000, bytesOut: 1_000_000),
            TimelinePoint(timestamp: t0 + 300, bytesIn: 4_000_000, bytesOut: 1_000_000),
        ]
        let rep = render(points, style: style)

        // 取左端点所在的窄带：填充是 28% 不透明度，所以 alpha 门槛要比线条低
        let blue = markRows(rep, xFrom: 0.24, xTo: 0.30, minAlpha: 0.15) {
            $0.blueComponent > 0.55 && $0.blueComponent - $0.redComponent > 0.25
        }
        let red = markRows(rep, xFrom: 0.24, xTo: 0.30, minAlpha: 0.15) {
            $0.redComponent > 0.55 && $0.redComponent - $0.blueComponent > 0.25
        }
        XCTAssertFalse(blue.isEmpty, "\(style.rawValue)：下载应该画出来")
        XCTAssertFalse(red.isEmpty, "\(style.rawValue)：上传应该画出来")

        let blueTop = blue.min() ?? 0, blueBottom = blue.max() ?? 0
        let redTop = red.min() ?? 0, redBottom = red.max() ?? 0
        XCTAssertLessThan(blueTop, redTop - 3, "\(style.rawValue)：下载整段都在零轴上方")
        XCTAssertGreaterThan(redBottom, blueBottom + 3,
                             "\(style.rawValue)：上传整段都在零轴下方（镜像），不叠在一起")
    }

    /// **回归**：没有采集的时段（机器休眠 / 应用没跑）——
    /// 折线补 0 连起来（不然会断成一截截），同时用灰带标出「这里没数据」，
    /// 免得把「没测到」看成「测到 0」。
    func testGapIsZeroFilledAndMarked() {
        let now = Date()
        let bucket: TimeInterval = 300
        let start = now.addingTimeInterval(-24 * 3_600).timeIntervalSince1970
        var points: [TimelinePoint] = []
        for index in 0 ... Int(24 * 3_600 / bucket) {
            let offsetHours = Double(index) * bucket / 3_600      // 0 = -24h
            // -17h…-13h 这 4 小时整机没采集；其余时间采集正常（没有流量就是真实 0）
            let covered = !(offsetHours > 7 && offsetHours < 11)
            // -18h 与 -12h 各有一处突发
            let burst = abs(offsetHours - 6) < 0.1 || abs(offsetHours - 12) < 0.1
            points.append(TimelinePoint(timestamp: start + Double(index) * bucket,
                                        bytesIn: burst ? 2_000_000 : 0,
                                        bytesOut: 0,
                                        isCovered: covered))
        }
        let rep = render(points)

        // 空洞落在 x ≈ 0.29…0.46（-17h…-13h），取中段
        let gray = firstColorColumn(rep, in: 0.33 ... 0.42) { color in
            color.alphaComponent > 0.05 && color.alphaComponent < 0.5
                && abs(color.redComponent - color.blueComponent) < 0.1
                && color.redComponent < 0.9
        }
        XCTAssertNotNil(gray, "没采集的时段要画灰带")

        // 0 值处两条线重合，后画的上行线会盖住下行线 —— 只要有一条在线即可
        let linePixels = bluePixels(rep, xFrom: 0.33, xTo: 0.42)
            + redPixels(rep, xFrom: 0.33, xTo: 0.42)
        XCTAssertGreaterThan(linePixels, 0, "补 0 之后折线要连续穿过空洞，不能断成一截截")
    }

    /// 在指定 x 比例区间里找第一列满足条件的像素
    private func firstColorColumn(_ rep: NSBitmapImageRep, in range: ClosedRange<Double>,
                                  where matches: (NSColor) -> Bool) -> Int? {
        for x in Int(Double(rep.pixelsWide) * range.lowerBound) ..< Int(Double(rep.pixelsWide) * range.upperBound) {
            for y in 0 ..< rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if matches(color) { return x }
            }
        }
        return nil
    }

}
