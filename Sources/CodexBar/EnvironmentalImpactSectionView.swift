import SwiftUI

struct EnvironmentalImpactSectionView: View {
    let lines: [String]
    let hintLine: String?
    let textFont: Font

    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        if !self.lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "leaf")
                        .foregroundColor(.green)
                        .imageScale(.small)
                    Text("environmental_impact_header")
                        .font(.body)
                        .fontWeight(.medium)
                }
                .padding(.top, 4)

                ForEach(self.lines, id: \.self) { line in
                    Text(line)
                        .font(self.textFont)
                }

                if let hintLine, !hintLine.isEmpty {
                    Text(hintLine)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
