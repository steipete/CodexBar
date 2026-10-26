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
                layoutModel: self.layoutModel,
                showBottomDivider: false,
                bottomPadding: self.bottomPadding,
                width: self.width)
        }
        .frame(width: self.width, alignment: .leading)
    }
}

struct MetricRowHeader: View {
    let title: String
    let layoutTitle: String
    let resetText: String?
    let layoutResetText: String?
    let isHighlighted: Bool

    var body: some View {
        if let layoutResetText {
            let resolvedResetText = self.resetText ?? layoutResetText
            ViewThatFits(in: .horizontal) {
                self.layoutPreservingHeader(
                    layout: self.horizontalHeader(title: self.layoutTitle, resetText: layoutResetText),
                    content: self.horizontalHeader(title: self.title, resetText: resolvedResetText))
                self.layoutPreservingHeader(
                    layout: self.verticalHeader(title: self.layoutTitle, resetText: layoutResetText),
                    content: self.verticalHeader(title: self.title, resetText: resolvedResetText))
            }
        } else {
            self.titleLabel(self.title)
        }
    }

    private func horizontalHeader(title: String, resetText: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            self.titleLabel(title)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            self.resetLabel(resetText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verticalHeader(title: String, resetText: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            self.titleLabel(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            self.resetLabel(resetText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func titleLabel(_ title: String) -> some View {
        Text(title)
            .font(.body)
            .fontWeight(.medium)
            .lineLimit(1)
    }

    private func resetLabel(_ resetText: String) -> some View {
        Text(resetText)
            .font(.footnote)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
    }

    private func layoutPreservingHeader(
        layout: some View,
        content: some View) -> some View
    {
        layout
            .hidden()
            .overlay(alignment: .topLeading) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipped()
    }
}
