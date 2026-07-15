import CoreGraphics
import SwiftUI

enum UsageMenuCardLayout {
    static let horizontalPadding: CGFloat = 20
    static let headerOnlyVerticalPadding: CGFloat = 6
    static let headerContentSpacing: CGFloat = 6
    static let sectionTopPadding: CGFloat = 6
    static let usageSectionTopPadding: CGFloat = 10
    static let sectionBottomPadding: CGFloat = 6
    static let headerLineSpacing: CGFloat = 4
    static let headerColumnSpacing: CGFloat = 12

    static var postHeaderDividerContentSpacing: CGFloat {
        // Reproduces Overview's header-bottom + usage-top gap so full cards align.
        sectionBottomPadding + usageSectionTopPadding
    }
}

struct MetricDetailRow: View {
    let leftText: String?
    let rightText: String?
    let secondaryRightText: String?
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        if let secondaryRightText {
            self.fixedTwoRow(secondaryRightText: secondaryRightText)
        } else {
            ViewThatFits(in: .horizontal) {
                self.oneRow
                self.twoRow
            }
        }
    }

    private func fixedTwoRow(secondaryRightText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let leftText {
                    self.detailText(leftText, color: MenuHighlightStyle.primary(self.isHighlighted))
                }
                Spacer(minLength: 8)
                if let rightText {
                    self.detailText(rightText, color: MenuHighlightStyle.secondary(self.isHighlighted))
                        .layoutPriority(1)
                }
            }
            self.detailText(secondaryRightText, color: MenuHighlightStyle.secondary(self.isHighlighted))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var oneRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let leftText {
                self.detailText(leftText, color: MenuHighlightStyle.primary(self.isHighlighted))
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 8)
            if let rightText {
                self.detailText(rightText, color: MenuHighlightStyle.secondary(self.isHighlighted))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var twoRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let leftText {
                self.detailText(leftText, color: MenuHighlightStyle.primary(self.isHighlighted))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let rightText {
                self.detailText(rightText, color: MenuHighlightStyle.secondary(self.isHighlighted))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func detailText(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(color).lineLimit(1)
    }
}
