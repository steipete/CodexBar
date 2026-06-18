import SwiftUI

struct UsageMenuCardHeaderAndUsageSectionView: View {
    let model: UsageMenuCardView.Model
    let layoutModel: UsageMenuCardView.Model
    let bottomPadding: CGFloat
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(
                model: self.layoutModel,
                showDivider: true,
                width: self.width)
            UsageMenuCardUsageSectionView(
                model: self.model,
                showBottomDivider: false,
                bottomPadding: self.bottomPadding,
                width: self.width)
        }
        .frame(width: self.width, alignment: .leading)
    }
}
