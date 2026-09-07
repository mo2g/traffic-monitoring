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
        WindowGroup {
            MainWindowView()
                .environment(collectorService)
                .environment(dashboardVM)
                .frame(minWidth: 800, minHeight: 500)
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
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environment(collectorService)
                .environment(dashboardVM)
        }
    }
}
