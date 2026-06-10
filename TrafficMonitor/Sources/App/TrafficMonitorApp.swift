import SwiftUI

@main
struct TrafficMonitorApp: App {
    @StateObject private var collectorService = CollectorService.shared
    @StateObject private var dashboardVM = DashboardViewModel()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(collectorService)
                .environmentObject(dashboardVM)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    dashboardVM.startObserving()
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
                .environmentObject(collectorService)
        }
    }
}
