import CodexBarCore
import SwiftUI

struct MenuCardTokenDetailsModel {
    static func lines(for request: CursorRecentRequest) -> [String] {
        UsageFormatter.cursorRequestDiagnosticLines(request)
    }
}

struct MenuCardTokenDetailsView: View {
    let request: CursorRecentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(MenuCardTokenDetailsModel.lines(for: self.request).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
        .padding(.top, 2)
    }
}
