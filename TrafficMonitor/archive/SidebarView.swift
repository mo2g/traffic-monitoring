import SwiftUI

/// 侧栏视图（占位）
///
/// Phase 2 将实现时间范围选择和进程搜索
struct SidebarView: View {
    var body: some View {
        List {
            Section("时间范围") {
                Label("今日", systemImage: "clock")
                Label("本周", systemImage: "calendar")
                Label("本月", systemImage: "calendar.badge.clock")
            }

            Section("搜索") {
                Label("搜索进程...", systemImage: "magnifyingglass")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}
