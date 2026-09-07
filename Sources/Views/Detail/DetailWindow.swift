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
        let bucket = TimelineBucket.size(for: range)
        let peakIn = Double(vm.timeline.map(\.bytesIn).max() ?? 0) / bucket
        let peakOut = Double(vm.timeline.map(\.bytesOut).max() ?? 0) / bucket

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
            stat(L("detail.dataPoints"), "\(vm.timeline.count)", .secondary)
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
private struct TrafficChart: View {
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
    }

    private var samples: [Sample] {
        points.flatMap { p -> [Sample] in
            let date = Date(timeIntervalSince1970: p.timestamp)
            return [
                Sample(date: date, rate: Double(p.bytesIn) / bucket, direction: L("chart.series.download")),
                Sample(date: date, rate: Double(p.bytesOut) / bucket, direction: L("chart.series.upload")),
            ]
        }
    }

    private var selectedPoint: TimelinePoint? {
        guard let selected else { return nil }
        return points.min {
            abs($0.timestamp - selected.timeIntervalSince1970)
                < abs($1.timestamp - selected.timeIntervalSince1970)
        }
    }

    var body: some View {
        Chart(samples) { s in
            switch style {
            case .line:
                LineMark(x: .value(L("chart.axis.time"), s.date), y: .value(L("chart.axis.rate"), s.rate))
                    .foregroundStyle(by: .value(L("chart.series"), s.direction))
                    .interpolationMethod(.catmullRom)   // 平滑曲线
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            case .area:
                // AreaMark 默认按分组**堆叠**，而 LineMark 不堆叠 ——
                // 混用会让红色面积的顶边远高于红色线，读数完全对不上。
                AreaMark(x: .value(L("chart.axis.time"), s.date), y: .value(L("chart.axis.rate"), s.rate),
                         stacking: .unstacked)
                    .foregroundStyle(by: .value(L("chart.series"), s.direction))
                    .interpolationMethod(.catmullRom)
                    .opacity(0.28)
                LineMark(x: .value(L("chart.axis.time"), s.date), y: .value(L("chart.axis.rate"), s.rate))
                    .foregroundStyle(by: .value(L("chart.series"), s.direction))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

            case .bar:
                // 柱状用并排而非堆叠，同样是为了让高度直接对应各自的速率
                BarMark(x: .value(L("chart.axis.time"), s.date), y: .value(L("chart.axis.rate"), s.rate))
                    .foregroundStyle(by: .value(L("chart.series"), s.direction))
                    .position(by: .value(L("chart.series"), s.direction))
                    .cornerRadius(2)
            }

            if let selectedPoint, s.date == Date(timeIntervalSince1970: selectedPoint.timestamp) {
                RuleMark(x: .value(L("chart.axis.time"), s.date))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale([L("chart.series.download"): Color.blue,
                                    L("chart.series.upload"): Color.red])
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
                        Text(ByteFormatter.rateString(bytesPerSecond: rate))
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

    private func tooltip(for point: TimelinePoint) -> some View {
        let stamp: Date.FormatStyle = range <= 86_400
            ? .dateTime.hour().minute()
            : .dateTime.month(.defaultDigits).day().hour().minute()
        return VStack(alignment: .leading, spacing: 3) {
            Text(Date(timeIntervalSince1970: point.timestamp).formatted(stamp))
                .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 10) {
                legend(.blue, "↓", rate: Double(point.bytesIn) / bucket, bytes: point.bytesIn)
                legend(.red, "↑", rate: Double(point.bytesOut) / bucket, bytes: point.bytesOut)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        .allowsHitTesting(false)
    }

    private func legend(_ color: Color, _ arrow: String, rate: Double, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(arrow) \(ByteFormatter.rateString(bytesPerSecond: rate))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(color)
            Text(ByteFormatter.string(bytes: bytes))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
