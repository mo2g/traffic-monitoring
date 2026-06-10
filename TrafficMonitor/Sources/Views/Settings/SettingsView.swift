import SwiftUI

/// 完整的设置窗口 (F5)
struct SettingsView: View {
    @EnvironmentObject var collectorService: CollectorService

    @State private var selectedInterval: TimeInterval = Constants.defaultInterval
    @State private var dbSize: String = "计算中..."
    @State private var retentionDays: Double = 30
    @State private var retentionEnabled: Bool = false
    @State private var excludedProcesses: String = ""

    var body: some View {
        TabView {
            // 采集设置
            Form {
                Section {
                    LabeledContent("采集间隔") {
                        Picker("", selection: $selectedInterval) {
                            Text("2 秒").tag(2.0)
                            Text("5 秒").tag(5.0)
                            Text("10 秒").tag(10.0)
                            Text("30 秒").tag(30.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: selectedInterval) { _, newValue in
                            collectorService.interval = newValue
                            // 重启定时器
                            if collectorService.status == .running {
                                collectorService.stop()
                                Task { await collectorService.start() }
                            }
                        }
                    }

                    LabeledContent("开机启动") {
                        Toggle("", isOn: .constant(false)).disabled(true)
                            .help("Phase 4 实现")
                    }
                } header: {
                    Text("采集设置")
                }

                Section {
                    LabeledContent("数据库大小") {
                        Text(dbSize)
                    }
                    .onAppear { updateDBSize() }

                    LabeledContent("自动清理") {
                        Toggle("", isOn: $retentionEnabled)
                    }

                    if retentionEnabled {
                        LabeledContent("保留天数") {
                            HStack {
                                Text("\(Int(retentionDays)) 天")
                                    .monospacedDigit()
                                Stepper("", value: $retentionDays, in: 7...90, step: 1)
                                    .labelsHidden()
                            }
                        }

                        Button("立即清理") {
                            deleteOldData()
                            updateDBSize()
                        }
                    }

                } header: {
                    Text("数据管理")
                }

                Section {
                    LabeledContent("排除进程") {
                        TextField("用逗号分隔进程名", text: $excludedProcesses)
                    }
                } header: {
                    Text("高级")
                }
            }
            .tabItem { Label("通用", systemImage: "gear") }
            .formStyle(.grouped)
            .padding()

            // 关于
            Form {
                Section {
                    LabeledContent("版本", value: "0.1.0 (MVP)")
                    LabeledContent("技术栈", value: "SwiftUI + GRDB + nettop")
                    LabeledContent("最低系统", value: "macOS 14.0 (Sonoma)")
                } header: {
                    Text("关于")
                }

                Section {
                    LabeledContent("采集方式", value: "nettop 子进程（持久 root）")
                    LabeledContent("提权方式", value: "AppleScript 弹窗（仅首次）")
                    LabeledContent("数据库", value: "SQLite (WAL mode, GRDB)")
                } header: {
                    Text("技术细节")
                }
            }
            .tabItem { Label("关于", systemImage: "info.circle") }
            .formStyle(.grouped)
            .padding()
        }
        .frame(width: 500, height: 400)
    }

    // MARK: - Actions

    private func updateDBSize() {
        Task {
            let size = await DataStore.shared.databaseSize()
            dbSize = ByteFormatter.string(bytes: size)
        }
    }

    private func deleteOldData() {
        let cutoff = Date().timeIntervalSince1970 - retentionDays * 86400
        Task {
            try? await DataStore.shared.deleteBefore(cutoff)
        }
    }
}
