import SwiftUI

/// 采集状态指示器（占位）
///
/// Phase 2 实现
struct StatusIndicator: View {
    let status: CollectorStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .idle, .stopped:   return .gray
        case .authorizing:      return .orange
        case .running:           return .green
        case .error:              return .red
        }
    }
}
