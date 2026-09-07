import SwiftUI
import UserNotifications
import AppKit

@main
@MainActor
struct TrafficMonitorApp: App {
    @State private var collectorService = CollectorService.shared
    @State private var dashboardVM = DashboardViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(id: MainWindowID.value) {
            MainWindowView()
                .environment(collectorService)
                .environment(dashboardVM)
                .frame(minWidth: 940, idealWidth: 1080, minHeight: 520, idealHeight: 680)
                .onAppear {
                    if Bundle.main.bundleIdentifier != nil {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                    dashboardVM.startObserving()
                    dashboardVM.loadGroups()
                    collectorService.loadAlertRules()
                    Task {
                        await collectorService.start()
                    }
                }
                .onDisappear {
                    dashboardVM.stopObserving()
                }
        }
        .windowStyle(.titleBar)
        // 默认宽度要放得下侧栏 + 六列表格，否则「合计」列会被挤出可视区、
        // 出现横向滚动条
        .defaultSize(width: 1080, height: 680)

        // 这里**不能**直接用 Bindable(collectorService).menuBarEnabled。
        //
        // MenuBarExtra 在每次场景更新时都会把当前值回写进绑定，而 @Observable
        // 的合成 setter 无条件调用 withMutation —— 即便值没变也会通知观察者。
        // App.body 读了这个属性，于是「求值 → 回写 → 失效 → 再求值」形成死循环，
        // 主线程 100% 占用、界面无响应。
        // 过滤掉同值写入，循环就断了。
        MenuBarExtra(isInserted: Binding(
            get: { collectorService.menuBarEnabled },
            set: { if $0 != collectorService.menuBarEnabled { collectorService.menuBarEnabled = $0 } }
        )) {
            MenuBarPanel()
                .environment(collectorService)
                .environment(dashboardVM)
        } label: {
            MenuBarLabel().environment(dashboardVM)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(collectorService)
                .environment(dashboardVM)
        }
    }
}
