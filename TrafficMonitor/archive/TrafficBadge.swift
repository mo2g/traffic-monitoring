import SwiftUI

/// 速率标签组件（占位）
struct TrafficBadge: View {
    let bytes: Int64
    let direction: Direction

    enum Direction {
        case download, upload
    }

    var body: some View {
        Text(ByteFormatter.stringCompact(bytes: bytes))
            .font(.caption.monospacedDigit())
    }
}
