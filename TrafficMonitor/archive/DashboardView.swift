import SwiftUI

/// 仪表盘视图（占位）
///
/// Phase 2 将实现完整的进程列表和速率概要
struct DashboardView: View {
    var body: some View {
        VStack {
            // 概要卡片
            HStack(spacing: 16) {
                SummaryCard(title: "下载速率", value: "—", icon: "arrow.down")
                SummaryCard(title: "上传速率", value: "—", icon: "arrow.up")
                SummaryCard(title: "今日流量", value: "—", icon: "chart.bar")
            }

            // 进程列表（占位）
            List {
                Text("采集启动后将在此显示进程流量")
                    .foregroundColor(.secondary)
            }
        }
    }
}
