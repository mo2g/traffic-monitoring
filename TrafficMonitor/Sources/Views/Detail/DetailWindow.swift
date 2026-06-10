import SwiftUI

// MARK: - Detail ViewModel

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var timeline: [TimelinePoint] = []
    @Published var selectedBucket: TimeInterval = 300

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

// MARK: - Detail Window (F7)

struct DetailWindow: View {
    let processKey: String
    let displayName: String

    @StateObject private var vm = DetailViewModel()
    @State private var timeRangeSeconds: TimeInterval = 86400

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(displayName).font(.title2.weight(.medium))
                Spacer()
                Picker("时间范围", selection: $timeRangeSeconds) {
                    Text("1 小时").tag(3600.0)
                    Text("6 小时").tag(21600.0)
                    Text("24 小时").tag(86400.0)
                    Text("7 天").tag(604800.0)
                }
                .pickerStyle(.segmented).frame(width: 300)
            }
            .padding()

            Divider()

            // Chart (simple bar chart without Charts framework)
            if vm.timeline.isEmpty {
                Spacer()
                Text("无数据").foregroundColor(.secondary)
                Spacer()
            } else {
                timelineChart.padding()
            }

            // Summary
            if !vm.timeline.isEmpty {
                let totalIn = vm.timeline.reduce(0) { $0 + $1.bytesIn }
                let totalOut = vm.timeline.reduce(0) { $0 + $1.bytesOut }

                HStack(spacing: 24) {
                    statBox("总下载", ByteFormatter.string(bytes: totalIn), color: .blue)
                    statBox("总上传", ByteFormatter.string(bytes: totalOut), color: .red)
                    statBox("合计", ByteFormatter.string(bytes: totalIn + totalOut))
                    statBox("数据点", "\(vm.timeline.count)")
                }
                .padding()
            }
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 500)
        .onAppear { loadData() }
        .onChange(of: timeRangeSeconds) { _,_ in loadData() }
    }

    // MARK: - Bar Chart

    private var timelineChart: some View {
        let maxVal = Double(vm.timeline.map { max($0.bytesIn, $0.bytesOut) }.max() ?? 1)

        return GeometryReader { geo in
            let barW = max((geo.size.width - 40) / CGFloat(vm.timeline.count) * 0.7, 2)
            let maxH = geo.size.height - 40

            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: max((geo.size.width - 40) / CGFloat(vm.timeline.count) * 0.3, 1)) {
                    ForEach(vm.timeline) { point in
                        let hIn = maxVal > 0 ? CGFloat(point.bytesIn) / CGFloat(maxVal) * maxH : 0
                        let hOut = maxVal > 0 ? CGFloat(point.bytesOut) / CGFloat(maxVal) * maxH : 0

                        VStack(spacing: 0) {
                            Spacer().frame(height: maxH - hOut - hIn)

                            // Upload (red, downward)
                            if hIn > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.blue.opacity(0.6))
                                    .frame(width: barW, height: max(hIn, 1))
                            }

                            // Download (blue, upward)
                            if hOut > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.red.opacity(0.6))
                                    .frame(width: barW, height: max(hOut, 1))
                            }

                            // Time label
                            Text(timeLabel(for: point.timestamp))
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                                .frame(width: barW * 2)
                        }
                    }
                }
                .frame(minWidth: geo.size.width - 20)
                .padding(.horizontal, 10)
            }
        }
    }

    private func timeLabel(for ts: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = timeRangeSeconds <= 3600 ? "mm:ss" : timeRangeSeconds <= 86400 ? "HH:mm" : "MM/dd"
        return f.string(from: date)
    }

    private func statBox(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline.monospacedDigit()).foregroundColor(color)
        }
    }

    private func loadData() {
        let since = Date().timeIntervalSince1970 - timeRangeSeconds
        Task { await vm.load(for: processKey, since: since) }
    }
}
