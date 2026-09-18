import Charts
import Combine
import SwiftUI

// MARK: - Detail ViewModel

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var timeline: [TimelinePoint] = []

    private var refreshTask: Task<Void, Never>?

    func startRefreshing(processKey: String, range: TimeInterval) {
        stopRefreshing()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load(processKey: processKey, range: range)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func load(processKey: String, range: TimeInterval) async {
        let since = Date().timeIntervalSince1970 - range
        let points = (try? await DataStore.shared.queryTimeline(
            processKey: processKey,
            since: since,
            bucketSeconds: TimelineBucket.size(for: range)
        )) ?? []
        if timeline != points { timeline = points }
    }
}

// MARK: - 时间桶

/// 时间桶随跨度自适应：跨度越大桶越粗，避免 7 天视图挤上千个点。
/// 纯函数，采集侧和视图侧共用同一套规则。
enum TimelineBucket {
    static func size(for range: TimeInterval) -> TimeInterval {
        switch range {
        case ..<7_200:    60      // ≤1h  → 1 分钟
        case ..<86_400:   300     // ≤24h → 5 分钟
        case ..<259_200:  1_800   // ≤3d  → 30 分钟
        default:          3_600   // 更长 → 1 小时
        }
    }

    /// 稀疏数据点的分段：相邻两点之间空了一个以上的桶 → 中间没有采集到数据，
    /// 线段必须断开。返回每个点所属的段号（从 0 开始，逐洞递增）。
    ///
    /// 阈值取 1.5 个桶：正常相邻是 1 个桶，缺一个就变成 2 个，跨过阈值即断。
    static func segmentIndices(_ points: [TimelinePoint], bucket: TimeInterval) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(points.count)
        var segment = 0
        var previous: TimeInterval?
        for point in points {
            if let previous, point.timestamp - previous > bucket * 1.5 {
                segment += 1
            }
            indices.append(segment)
            previous = point.timestamp
        }
        return indices
    }
}

// MARK: - 图表样式

enum ChartStyle: String, CaseIterable, Identifiable {
    // rawValue 是**持久化用的稳定标识**，不是展示文案。
    // 一开始把中文显示名直接当 rawValue 存进 UserDefaults，
    // 这既让存储内容依赖界面语言（将来做多语言时旧偏好全部失效），
    // 也让 Picker 的初始选中项对不上。展示文案走 `label`。
    case line, area, bar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: L("detail.style.line")
        case .area: L("detail.style.area")
        case .bar:  L("detail.style.bar")
        }
    }

    var symbol: String {
        switch self {
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .bar:  "chart.bar.fill"
        }
    }
}

// MARK: - Detail Window

@MainActor
struct DetailWindow: View {
    let row: ProcessRow

    @Environment(\.dismiss) private var dismiss
    @Environment(DashboardViewModel.self) private var dashboard
    @StateObject private var vm = DetailViewModel()

    @AppStorage("com.trafficmonitor.detail.range") private var range: Double = 86_400
    @AppStorage("com.trafficmonitor.detail.style") private var styleRaw: String = ChartStyle.line.rawValue

    private var style: ChartStyle { ChartStyle(rawValue: styleRaw) ?? .line }

    /// 实时速率直接读管线推来的行快照，不另设定时器
    private var live: ProcessRow? { dashboard.rows.first { $0.key == row.key } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summaryBar.padding(.horizontal).padding(.vertical, 10)
            Divider()
            chartArea
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 600)
        .onAppear { vm.startRefreshing(processKey: row.key, range: range) }
        .onDisappear { vm.stopRefreshing() }
        .onChange(of: range) { _, newValue in
            vm.startRefreshing(processKey: row.key, range: newValue)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ProcessIcon(row: row, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName).font(.title3.weight(.medium))
                if let bundleId = row.bundleId {
                    Text(bundleId).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("", selection: $range) {
                Text(L("detail.range.1h")).tag(3_600.0)
                Text(L("detail.range.6h")).tag(21_600.0)
                Text(L("detail.range.24h")).tag(86_400.0)
                Text(L("detail.range.7d")).tag(604_800.0)
            }
            .pickerStyle(.segmented).frame(width: 230).labelsHidden()

            Picker("", selection: $styleRaw) {
                ForEach(ChartStyle.allCases) { s in
                    Image(systemName: s.symbol).tag(s.rawValue).help(s.label)
                }
            }
            .pickerStyle(.segmented).frame(width: 110).labelsHidden()
            .help(L("detail.chartStyle.help"))

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help(L("detail.close"))
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    // MARK: Summary

    private var summaryBar: some View {
        let totalIn = vm.timeline.reduce(0) { $0 + $1.bytesIn }
        let totalOut = vm.timeline.reduce(0) { $0 + $1.bytesOut }
        // 峰值取桶内记下的最高瞬时速率，而不是「桶字节 ÷ 桶长」——
        // 后者是均值，10 秒跑满 22 Gbps 会被摊成 3.8 Gbps
        let peakIn = vm.timeline.map(\.peakIn).max() ?? 0
        let peakOut = vm.timeline.map(\.peakOut).max() ?? 0

        return HStack(spacing: 0) {
            stat(L("detail.liveDownload"), ByteFormatter.rateString(bytesPerSecond: live?.rxRate ?? 0),
                 .blue, highlight: (live?.rxRate ?? 0) > 0)
            divider
            stat(L("detail.liveUpload"), ByteFormatter.rateString(bytesPerSecond: live?.txRate ?? 0),
                 .red, highlight: (live?.txRate ?? 0) > 0)
            divider
            stat(L("detail.rangeDownload"), ByteFormatter.string(bytes: totalIn), .blue)
            divider
            stat(L("detail.rangeUpload"), ByteFormatter.string(bytes: totalOut), .red)
            divider
            stat(L("detail.total"), ByteFormatter.string(bytes: totalIn + totalOut))
            divider
            stat(L("detail.peakDownload"), ByteFormatter.rateString(bytesPerSecond: peakIn), .blue.opacity(0.7))
            divider
            stat(L("detail.peakUpload"), ByteFormatter.rateString(bytesPerSecond: peakOut), .red.opacity(0.7))
            Spacer()
            // 补零之后 timeline 里大部分点是「采集到了但没流量」，
            // 这里只数真有流量的那些点
            stat(L("detail.dataPoints"),
                 "\(vm.timeline.filter { $0.totalBytes > 0 }.count)", .secondary)
        }
    }

    private var divider: some View {
        Divider().frame(height: 28).padding(.horizontal, 12)
    }

    private func stat(_ label: String, _ value: String,
                     _ color: Color = .primary, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(highlight ? color : .secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    // MARK: Chart

    @ViewBuilder
    private var chartArea: some View {
        if vm.timeline.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "chart.xyaxis.line").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(L("detail.noData")).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TrafficChart(points: vm.timeline, style: style, range: range)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        }
    }
}

// MARK: - 图表

/// 用 Swift Charts 重写。
///
/// 旧实现是手绘 `Path` + 手算坐标 + 手摆刻度标签，约 200 行，只能画直线折线，
/// 且坐标轴刻度、hover 命中、深色模式配色都得自己维护。
/// Swift Charts 直接给出平滑插值、原生坐标轴与选取覆盖层，样式切换也只是换 Mark 类型。
struct TrafficChart: View {
    let points: [TimelinePoint]
    let style: ChartStyle
    let range: TimeInterval

    /// 光标选中的时间点
    @State private var selected: Date?

    private var bucket: TimeInterval { TimelineBucket.size(for: range) }

    /// 图表按**速率**画而不是按字节，这样换时间跨度（桶大小随之改变）时纵轴含义保持一致
    private struct Sample: Identifiable {
        /// 用「时间 + 方向」做稳定 id：若用 UUID()，每次刷新都是全新身份，
        /// Chart 会把整幅图当作新数据重画并重跑动画。
        var id: String { "\(date.timeIntervalSince1970)-\(direction)" }
        let date: Date
        let rate: Double
        let direction: String
        /// 所属线段。相邻数据点之间空了一个桶就换段 —— 画线时不能跨段连，
        /// 否则「6 小时没有数据」会被画成一条斜线。
        let segment: Int
        /// 这一段只有它自己：断线之后得画个圆点，不然什么都没有。
        let isIsolated: Bool

        /// 画线的分组键：**段 × 方向**。
        /// 只按段分组会把同一段的「下载点」和「上传点」连起来，画出一条竖线。
        var seriesKey: String { "\(direction)#\(segment)" }
    }

    private var samples: [Sample] {
        let segments = TimelineBucket.segmentIndices(points, bucket: bucket)
        var sizeBySegment: [Int: Int] = [:]
        for segment in segments { sizeBySegment[segment, default: 0] += 1 }

        return points.enumerated().flatMap { index, p -> [Sample] in
            let date = Date(timeIntervalSince1970: p.timestamp)
            let segment = segments[index]
            let isolated = sizeBySegment[segment] == 1
            return [
                // 下载在零轴上方、上传镜像到轴下方：两个方向的填充不再互相叠色
                // （叠出来是既不像蓝也不像红的紫），柱状也不会叠成一根。
                Sample(date: date, rate: Double(p.bytesIn) / bucket,
                       direction: L("chart.series.download"), segment: segment, isIsolated: isolated),
                Sample(date: date, rate: -Double(p.bytesOut) / bucket,
                       direction: L("chart.series.upload"), segment: segment, isIsolated: isolated),
            ]
        }
    }

    private var selectedPoint: TimelinePoint? {
        guard let selected,
              let nearest = points.min(by: {
                  abs($0.timestamp - selected.timeIntervalSince1970)
                      < abs($1.timestamp - selected.timeIntervalSince1970)
              })
        else { return nil }
        // 光标落在空洞里（离最近的数据点超过一个桶）时不弹气泡 ——
        // 那里没有数据，弹一个远处的读数反而是误导
        return abs(nearest.timestamp - selected.timeIntervalSince1970) <= bucket ? nearest : nil
    }

    var body: some View {
        Chart {
            // 零轴：下载在上、上传在下。加一条淡线，镜像关系一眼可见
            RuleMark(y: .value(L("chart.axis.rate"), 0))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))

            ForEach(samples) { s in
                switch style {
                case .line:
                    // series 按段分组：空洞两侧的点属于不同 series，线不会跨过去
                    LineMark(x: .value(L("chart.axis.time"), s.date),
                             y: .value(L("chart.axis.rate"), s.rate),
                             series: .value("series", s.seriesKey))
                        .foregroundStyle(by: .value(L("chart.series"), s.direction))
                        .symbol { isolatedSymbol(s) }
                        .interpolationMethod(.monotone)      // 平滑但不过冲：catmullRom 会在尖峰两侧冲出负值
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                case .area:
                    // 两个方向镜像分居零轴两侧，各自从 0 填到自己的数值
                    // 必须显式 .unstacked：AreaMark 默认按分组堆叠，镜像图里会把两个
                    // 方向摞到一起（紫一块蓝一块，读数完全对不上 —— 0.7.x 修过一次，
                    // 换成 yStart/yEnd 那个重载时又踩回去了，它没有 stacking 参数）。
                    AreaMark(x: .value(L("chart.axis.time"), s.date),
                             y: .value(L("chart.axis.rate"), s.rate),
                             series: .value("series", s.seriesKey),
                             stacking: .unstacked)
                        .foregroundStyle(by: .value(L("chart.series"), s.direction))
                        .interpolationMethod(.monotone)      // 同上，速率不能过冲到轴的另一侧
                        .opacity(0.28)
                    LineMark(x: .value(L("chart.axis.time"), s.date),
                             y: .value(L("chart.axis.rate"), s.rate),
                             series: .value("series", s.seriesKey))
                        .foregroundStyle(by: .value(L("chart.series"), s.direction))
                        .symbol { isolatedSymbol(s) }
                        .interpolationMethod(.monotone)      // 同上，速率不能过冲到轴的另一侧
                        .lineStyle(StrokeStyle(lineWidth: 1.5))

                case .bar:
                    // 柱状：下载向上、上传向下。**不能**再 position(by:) ——
                    // 那两个方向在轴两侧本来就分开了，再并排只会画歪；
                    // 而同侧堆叠更糟：高度会变成两者之和。
                    BarMark(x: .value(L("chart.axis.time"), s.date), y: .value(L("chart.axis.rate"), s.rate))
                        .foregroundStyle(by: .value(L("chart.series"), s.direction))
                        .cornerRadius(2)
                }

                if let selectedPoint, s.date == Date(timeIntervalSince1970: selectedPoint.timestamp) {
                    RuleMark(x: .value(L("chart.axis.time"), s.date))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        // 固定成「所选跨度」而不是按数据自适应：只有一两个点时，
        // 自适应会把轴压到那两点上，位置信息就没了
        .chartXScale(domain: Date().addingTimeInterval(-range) ... Date())
        .chartForegroundStyleScale([L("chart.series.download"): seriesColor(L("chart.series.download")),
                                    L("chart.series.upload"): seriesColor(L("chart.series.upload"))])
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisTick()
                AxisValueLabel(format: axisDateFormat)
                    .font(.system(size: 9, design: .monospaced))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let rate = value.as(Double.self) {
                        // 镜像图：标签给幅值，方向看上/下位置与图例
                        Text(ByteFormatter.rateString(bytesPerSecond: abs(rate)))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let selectedPoint, let plotFrame = proxy.plotFrame {
                    tooltip(for: selectedPoint)
                        .position(
                            x: tooltipX(for: selectedPoint, proxy: proxy, geo: geo, plot: plotFrame),
                            y: 26
                        )
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var axisDateFormat: Date.FormatStyle {
        range <= 86_400
            ? .dateTime.hour().minute()
            : .dateTime.month(.defaultDigits).day().hour()
    }

    private func tooltipX(for point: TimelinePoint, proxy: ChartProxy,
                          geo: GeometryProxy, plot: Anchor<CGRect>) -> CGFloat {
        let date = Date(timeIntervalSince1970: point.timestamp)
        let plotRect = geo[plot]
        let x = (proxy.position(forX: date) ?? 0) + plotRect.origin.x
        // 贴边时把气泡拉回可视区内
        return min(max(x, 90), geo.size.width - 90)
    }

    /// 孤点（这一段只有它自己）画个小圆点；成段的点不画，免得密数据糊成一片。
    ///
    /// 自定义符号**不会**继承 mark 的 `foregroundStyle`，得自己上色 ——
    /// 否则会落回系统强调色（蓝），上传方向的孤点会跟着变蓝。
    @ViewBuilder
    private func isolatedSymbol(_ sample: Sample) -> some View {
        if sample.isIsolated {
            Circle()
                .fill(seriesColor(sample.direction))
                .frame(width: 5, height: 5)
        }
    }

    /// 系列色只在两处用：样式表与孤点符号。两处必须一致。
    private func seriesColor(_ direction: String) -> Color {
        direction == L("chart.series.upload") ? .red : .blue
    }

    private func tooltip(for point: TimelinePoint) -> some View {
        let stamp: Date.FormatStyle = range <= 86_400
            ? .dateTime.hour().minute()
            : .dateTime.month(.defaultDigits).day().hour().minute()
        return VStack(alignment: .leading, spacing: 3) {
            // 「07:58 · 1 分钟」：一个点代表的是一段聚合，不是瞬时采样
            HStack(spacing: 4) {
                Text(Date(timeIntervalSince1970: point.timestamp).formatted(stamp))
                Text("· \(spanLabel(bucket))").foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 10) {
                legend(.blue, "↓", average: Double(point.bytesIn) / bucket,
                       peak: point.peakIn, bytes: point.bytesIn)
                legend(.red, "↑", average: Double(point.bytesOut) / bucket,
                       peak: point.peakOut, bytes: point.bytesOut)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .allowsHitTesting(false)
    }

    /// 速率两行：均速一行，峰值明显高出时再补一行 ——
    /// 平稳流量下两者几乎重合，显示两遍只会把气泡撑大。
    private func legend(_ color: Color, _ arrow: String,
                        average: Double, peak: Double, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(arrow) \(ByteFormatter.rateString(bytesPerSecond: average))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(color)
            if peak > average * 1.05 {
                Text("\(arrow) \(L("detail.peakShort")) \(ByteFormatter.rateString(bytesPerSecond: peak))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(color.opacity(0.75))
            }
            Text(ByteFormatter.string(bytes: bytes))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    /// 「1 分钟 / 5 分钟」：交回系统按当前语言排版，不再加一条文案键
    private func spanLabel(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }
}
