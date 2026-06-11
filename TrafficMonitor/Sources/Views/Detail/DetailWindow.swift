import SwiftUI
import Combine

// MARK: - Detail ViewModel

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var timeline: [TimelinePoint] = []
    @Published var selectedBucket: TimeInterval = 300

    private var refreshTimer: Timer?

    func startRefreshing(processKey: String, timeRangeSeconds: TimeInterval) {
        stopRefreshing()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            let since = Date().timeIntervalSince1970 - timeRangeSeconds
            let key = processKey
            Task { @MainActor [weak self] in
                await self?.load(for: key, since: since)
            }
        }
        // Fire immediately
        let since = Date().timeIntervalSince1970 - timeRangeSeconds
        Task { await load(for: processKey, since: since) }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func load(for processKey: String, since: TimeInterval) async {
        do {
            timeline = try await DataStore.shared.queryTimeline(
                processKey: processKey,
                since: since,
                bucketSeconds: selectedBucket
            )
        } catch {
            timeline = []
        }
    }
}

// MARK: - Detail Window

struct DetailWindow: View {
    let processKey: String
    let displayName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = DetailViewModel()
    @State private var timeRangeSeconds: TimeInterval = 86400

    /// 当前实时速率（从共享单例读取，每秒由 DashboardVM 触发更新）
    private var currentRx: Double {
        CollectorService.shared.latestDeltas
            .filter { $0.identifier.description == processKey }
            .reduce(0) { $0 + $1.rxRate }
    }
    private var currentTx: Double {
        CollectorService.shared.latestDeltas
            .filter { $0.identifier.description == processKey }
            .reduce(0) { $0 + $1.txRate }
    }

    // 定时刷新实时数据
    @State private var tick: Int = 0
    private let realtimeTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let chartHeight: CGFloat = 300
    private let padLeft: CGFloat   = 56
    private let padRight: CGFloat  = 20
    private let padTop: CGFloat    = 12
    private let padBottom: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundColor(.accentColor)
                Text(displayName).font(.title3.weight(.medium))
                Spacer()
                Picker("", selection: $timeRangeSeconds) {
                    Text("1 小时").tag(3600.0)
                    Text("6 小时").tag(21600.0)
                    Text("24 小时").tag(86400.0)
                    Text("7 天").tag(604800.0)
                }
                .pickerStyle(.segmented).frame(width: 240)
                .onChange(of: timeRangeSeconds) { _, _ in
                    vm.stopRefreshing()
                    vm.startRefreshing(processKey: processKey, timeRangeSeconds: timeRangeSeconds)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.secondary)
                }
                .buttonStyle(.plain).help("关闭 (Esc)")
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal).padding(.vertical, 10)

            Divider()

            // Summary
            summaryBar.padding(.horizontal).padding(.vertical, 10)
            Divider()

            // Chart
            if vm.timeline.isEmpty {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 28)).foregroundColor(.secondary)
                    Text("无数据").foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            } else {
                ChartView(
                    points: vm.timeline,
                    timeRangeSeconds: timeRangeSeconds,
                    chartHeight: chartHeight,
                    padLeft: padLeft, padRight: padRight,
                    padTop: padTop, padBottom: padBottom
                )
            }
        }
        .frame(minWidth: 660, idealWidth: 800, minHeight: 480, idealHeight: 560)
        .onAppear { vm.startRefreshing(processKey: processKey, timeRangeSeconds: timeRangeSeconds) }
        .onDisappear { vm.stopRefreshing() }
        .onReceive(realtimeTimer) { _ in tick &+= 1 }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        let totalIn  = vm.timeline.reduce(0) { $0 + $1.bytesIn }
        let totalOut = vm.timeline.reduce(0) { $0 + $1.bytesOut }
        let peakIn   = vm.timeline.map(\.bytesIn).max() ?? 1
        let peakOut  = vm.timeline.map(\.bytesOut).max() ?? 1

        return HStack(spacing: 0) {
            statCol("实时下载",  ByteFormatter.rateString(bytesPerSecond: currentRx), .blue, highlight: currentRx > 0)
            Divider().frame(height: 28).padding(.horizontal, 12)
            statCol("实时上传",  ByteFormatter.rateString(bytesPerSecond: currentTx), .red, highlight: currentTx > 0)
            Divider().frame(height: 28).padding(.horizontal, 12)
            statCol("总下载",  ByteFormatter.string(bytes: totalIn), .blue)
            Divider().frame(height: 28).padding(.horizontal, 12)
            statCol("总上传",  ByteFormatter.string(bytes: totalOut), .red)
            Divider().frame(height: 28).padding(.horizontal, 12)
            statCol("合计",    ByteFormatter.string(bytes: totalIn + totalOut))
            Divider().frame(height: 28).padding(.horizontal, 12)
            statCol("峰值下载", ByteFormatter.rateString(bytesPerSecond: Double(peakIn) / 300),  .blue.opacity(0.7))
            Divider().frame(height: 28).padding(.horizontal, 12)
            statCol("峰值上传", ByteFormatter.rateString(bytesPerSecond: Double(peakOut) / 300), .red.opacity(0.7))
            Spacer()
            statCol("数据点",  "\(vm.timeline.count)", .secondary)
        }
    }

    private func statCol(_ label: String, _ value: String, _ color: Color = .primary, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundColor(highlight ? color : .secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(color)
        }
    }
}

// MARK: - Chart View (extracted for clean hover state management)

private struct ChartView: View {
    let points: [TimelinePoint]
    let timeRangeSeconds: TimeInterval
    let chartHeight: CGFloat
    let padLeft: CGFloat
    let padRight: CGFloat
    let padTop: CGFloat
    let padBottom: CGFloat

    @State private var hoverLocation: CGPoint?
    @State private var hoveredIndex: Int?

    private var labelFmt: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = timeRangeSeconds <= 3600  ? "HH:mm"
                     : timeRangeSeconds <= 86400 ? "HH:mm"
                     :                             "MM/dd HH"
        return f
    }

    var body: some View {
        let count    = points.count
        let maxVal   = Double(points.map { max($0.bytesIn, $0.bytesOut) }.max() ?? 1)
        let yMax     = maxVal == 0 ? 1 : maxVal * 1.15

        GeometryReader { geo in
            let w  = geo.size.width
            let h  = geo.size.height
            let cw = max(w - padLeft - padRight, 1)
            let ch = max(h - padTop - padBottom, 1)

            ZStack(alignment: .topLeading) {
                // ── Grid ──
                ForEach(0...4, id: \.self) { i in
                    let y = padTop + ch * CGFloat(i) / 4
                    Path { p in
                        p.move(to: CGPoint(x: padLeft, y: y))
                        p.addLine(to: CGPoint(x: w - padRight, y: y))
                    }
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }

                // ── Lines ──
                Path { path in
                    guard count >= 1 else { return }
                    for (i, pt) in points.enumerated() {
                        let x = padLeft + cw * CGFloat(i) / CGFloat(max(count - 1, 1))
                        let y = padTop + ch * (1.0 - CGFloat(Double(pt.bytesIn) / yMax))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else      { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                Path { path in
                    guard count >= 1 else { return }
                    for (i, pt) in points.enumerated() {
                        let x = padLeft + cw * CGFloat(i) / CGFloat(max(count - 1, 1))
                        let y = padTop + ch * (1.0 - CGFloat(Double(pt.bytesOut) / yMax))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else      { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.red, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // ── Y labels ──
                ForEach(0...4, id: \.self) { i in
                    let y = padTop + ch * CGFloat(i) / 4
                    let v = yMax * Double(4 - i) / 4
                    Text(ByteFormatter.stringCompact(bytes: Int64(v)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: padLeft - 8, alignment: .trailing)
                        .position(x: (padLeft - 8) / 2, y: y)
                }

                // ── X labels ──
                let xStep = max(count / 6, 1)
                ForEach(0..<count, id: \.self) { i in
                    if i % xStep == 0 || i == count - 1 {
                        let x = padLeft + cw * CGFloat(i) / CGFloat(max(count - 1, 1))
                        Text(labelFmt.string(from: Date(timeIntervalSince1970: points[i].timestamp)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize()
                            .position(x: x, y: padTop + ch + padBottom)
                    }
                }

                // ── Hover highlight dot ──
                if let idx = hoveredIndex, idx < count {
                    let x = padLeft + cw * CGFloat(idx) / CGFloat(max(count - 1, 1))
                    let inY  = padTop + ch * (1.0 - CGFloat(Double(points[idx].bytesIn)  / yMax))
                    let outY = padTop + ch * (1.0 - CGFloat(Double(points[idx].bytesOut) / yMax))
                    Circle().fill(.blue).frame(width: 5, height: 5).position(x: x, y: inY)
                    Circle().fill(.red).frame(width: 5, height: 5).position(x: x, y: outY)
                    // Thin crosshair line
                    Path { p in
                        p.move(to: CGPoint(x: x, y: padTop))
                        p.addLine(to: CGPoint(x: x, y: padTop + ch))
                    }
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                }

                // ── Legend ──
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.blue).frame(width: 6, height: 6)
                        Text("下载").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("上传").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
                .position(x: 85, y: padTop + 12)
            }
            // ── Hover detection layer over entire chart area ──
            .overlay {
                if let idx = hoveredIndex, idx < count {
                    tooltipOverlay(for: points[idx], idx: idx, cw: cw, ch: ch)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    let chartX = location.x - padLeft
                    let rawIdx = Int(round(chartX / cw * CGFloat(max(count - 1, 1))))
                    hoveredIndex = min(max(rawIdx, 0), max(count - 1, 0))
                case .ended:
                    hoverLocation = nil
                    hoveredIndex = nil
                }
            }
        }
        .frame(height: chartHeight + padTop + padBottom)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func tooltipOverlay(for pt: TimelinePoint, idx: Int, cw: CGFloat, ch: CGFloat) -> some View {
        let count = points.count
        let x = padLeft + cw * CGFloat(idx) / CGFloat(max(count - 1, 1))
        let time = labelFmt.string(from: Date(timeIntervalSince1970: pt.timestamp))
        VStack(alignment: .leading, spacing: 3) {
            Text(time).font(.system(size: 11, weight: .semibold))
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Circle().fill(.blue).frame(width: 5, height: 5)
                    Text("↓\(ByteFormatter.string(bytes: pt.bytesIn))")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.blue)
                }
                HStack(spacing: 3) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    Text("↑\(ByteFormatter.string(bytes: pt.bytesOut))")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .position(x: clampX(x), y: padTop - 36)
    }

    private func clampX(_ x: CGFloat) -> CGFloat {
        min(max(x, 100), 480)
    }
}
