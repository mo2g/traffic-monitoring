import SwiftUI

/// 进程行组件（占位）
///
/// Phase 2 实现
struct ProcessRow: View {
    let name: String
    let bytesIn: Int64
    let bytesOut: Int64

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text("↓\(ByteFormatter.stringCompact(bytes: bytesIn))")
                .foregroundColor(.blue)
            Text("↑\(ByteFormatter.stringCompact(bytes: bytesOut))")
                .foregroundColor(.red)
        }
    }
}
