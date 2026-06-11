import SwiftUI

/// 完整的设置窗口 (F5)
struct SettingsView: View {
    @EnvironmentObject var collectorService: CollectorService
    @EnvironmentObject var dashboardVM: DashboardViewModel

    @State private var selectedInterval: TimeInterval = Constants.defaultInterval
    @State private var selectedSaveInterval: TimeInterval = Constants.batchSaveInterval
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
                            Text("1 秒").tag(1.0)
                            Text("2 秒").tag(2.0)
                            Text("5 秒").tag(5.0)
                            Text("10 秒").tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: selectedInterval) { _, newValue in
                            collectorService.interval = newValue
                            if collectorService.status == .running {
                                collectorService.stop()
                                Task { await collectorService.start() }
                            }
                        }
                    }

                    LabeledContent("保存间隔") {
                        Picker("", selection: $selectedSaveInterval) {
                            Text("3 秒").tag(3.0)
                            Text("5 秒").tag(5.0)
                            Text("10 秒").tag(10.0)
                            Text("30 秒").tag(30.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: selectedSaveInterval) { _, newValue in
                            collectorService.saveInterval = newValue
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

            // 分组管理
            groupTabView
                .tabItem { Label("分组", systemImage: "square.grid.2x2") }
                .formStyle(.grouped)
                .padding()

            // 告警设置
            alertTabView
                .tabItem { Label("告警", systemImage: "bell.badge") }
                .formStyle(.grouped)
                .padding()

            // 调试日志
            logTabView
                .tabItem { Label("日志", systemImage: "text.alignleft") }
                .padding()

            Form {
                Section {
                    LabeledContent("版本", value: "0.2.0 (P2)")
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

    // MARK: - Alert Tab

    @State private var alertRules: [AlertRule] = []
    @State private var newAlertProcess: String = ""
    @State private var newAlertBytes: String = ""
    @State private var newAlertRate: String = ""

    private var alertTabView: some View {
        Form {
            Section {
                if alertRules.isEmpty {
                    HStack { Spacer(); Text("暂无告警规则").foregroundColor(.secondary); Spacer() }
                } else {
                    ForEach($alertRules) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.enabled).labelsHidden().frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.displayName).lineLimit(1)
                                Text(rule.processKey ?? "全局")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .contextMenu { Button("删除", role: .destructive) { alertRules.removeAll { $0.id == rule.id }; saveAlertRules() } }
                    }
                }
            } header: {
                Text("现有规则")
            }

            Section {
                TextField("进程名（留空=全局）", text: $newAlertProcess)
                TextField("字节阈值（如 104857600）", text: $newAlertBytes)
                TextField("速率阈值 B/s（如 1048576）", text: $newAlertRate)
                Button("添加规则") {
                    guard !newAlertBytes.isEmpty || !newAlertRate.isEmpty else { return }
                    let key = newAlertProcess.trimmingCharacters(in: .whitespaces)
                    let name = key.isEmpty ? "全局" : key
                    let rule = AlertRule(
                        processKey: key.isEmpty ? nil : key,
                        displayName: "\(name) 告警",
                        thresholdBytes: Int64(newAlertBytes),
                        thresholdRate: Double(newAlertRate)
                    )
                    alertRules.append(rule)
                    saveAlertRules()
                    newAlertProcess = ""
                    newAlertBytes = ""
                    newAlertRate = ""
                }
                .disabled(newAlertBytes.isEmpty && newAlertRate.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            } header: {
                Text("新建规则")
            }
        }
        .onAppear { alertRules = collectorService.alertRules }
    }

    private func saveAlertRules() {
        collectorService.alertRules = alertRules
        AlertStore.shared.save(alertRules)
    }

    // MARK: - Group Tab

    @State private var processGroups: [ProcessGroup] = []
    @State private var newGroupName: String = ""
    @State private var newGroupKeys: String = ""

    private var groupTabView: some View {
        Form {
            Section {
                if processGroups.isEmpty {
                    HStack { Spacer(); Text("暂无分组").foregroundColor(.secondary); Spacer() }
                } else {
                    ForEach(processGroups) { group in
                        HStack {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).lineLimit(1)
                                Text(group.processKeys.sorted().joined(separator: ", "))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(group.processKeys.count)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                        .contextMenu { Button("删除", role: .destructive) { processGroups.removeAll { $0.id == group.id }; saveGroups() } }
                    }
                }
            } header: {
                Text("现有分组")
            }

            Section {
                TextField("分组名称", text: $newGroupName)
                TextField("进程键（逗号分隔）", text: $newGroupKeys)
                Button("创建分组") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    let keys = Set(newGroupKeys.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    guard !name.isEmpty, !keys.isEmpty else { return }
                    processGroups.append(ProcessGroup(name: name, processKeys: keys))
                    saveGroups()
                    newGroupName = ""
                    newGroupKeys = ""
                }
                .disabled(newGroupName.isEmpty || newGroupKeys.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            } header: {
                Text("新建分组")
            }
        }
        .onAppear { processGroups = dashboardVM.processGroups }
    }

    private func saveGroups() {
        dashboardVM.processGroups = processGroups
        GroupStore.shared.save(processGroups)
    }

    // MARK: - Log Tab

    @State private var logEntries: [LogEntry] = []
    @State private var logFilter: LogEntry.Level? = nil

    private var logTabView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("过滤", selection: $logFilter) {
                    Text("全部").tag(nil as LogEntry.Level?)
                    ForEach(LogEntry.Level.allCases, id: \.self) { lvl in
                        Text(lvl.rawValue).tag(lvl as LogEntry.Level?)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Button("刷新") { Task { await loadLogs() } }

                Spacer()

                Text("最近 50 条").font(.caption).foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLogs) { entry in
                        HStack(spacing: 4) {
                            Text(formatLogTime(entry.timestamp))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(entry.level.rawValue)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(logLevelColor(entry.level))
                            Text("[\(entry.tag)]")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(entry.message)
                                .font(.system(size: 11))
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear { Task { await loadLogs() } }
    }

    private var filteredLogs: [LogEntry] {
        let all = logEntries
        guard let filter = logFilter else { return all }
        return all.filter { $0.level == filter }
    }

    private func loadLogs() async {
        logEntries = await LogStore.shared.recentEntries(count: 50)
    }

    private func formatLogTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func logLevelColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
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
