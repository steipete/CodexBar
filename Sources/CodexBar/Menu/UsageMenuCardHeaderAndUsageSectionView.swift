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
    var percentText: String?
    var layoutPercentText: String?

    var body: some View {
        if let layoutResetText {
            let resolvedResetText = self.resetText ?? layoutResetText
            ViewThatFits(in: .horizontal) {
                self.layoutPreservingHeader(
                    layout: self.horizontalHeader(
                        title: self.layoutTitle,
                        percentText: self.layoutPercentText,
                        resetText: layoutResetText),
                    content: self.horizontalHeader(
                        title: self.title,
                        percentText: self.percentText,
                        resetText: resolvedResetText))
                self.layoutPreservingHeader(
                    layout: self.verticalHeader(
                        title: self.layoutTitle,
                        percentText: self.layoutPercentText,
                        resetText: layoutResetText),
                    content: self.verticalHeader(
                        title: self.title,
                        percentText: self.percentText,
                        resetText: resolvedResetText))
            }
        } else {
            self.titleLabel(self.title, percentText: self.percentText)
        }
    }

    private func horizontalHeader(title: String, percentText: String?, resetText: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            self.titleLabel(title, percentText: percentText)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            self.resetLabel(resetText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verticalHeader(title: String, percentText: String?, resetText: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            self.titleLabel(title, percentText: percentText)
                .frame(maxWidth: .infinity, alignment: .leading)
            self.resetLabel(resetText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func titleLabel(_ title: String, percentText: String?) -> some View {
        (Text(title) + Text(percentText.map { " " + $0 } ?? "").monospacedDigit())
            .font(.body)
            .fontWeight(.medium)
            .lineLimit(1)
    }

    private func resetLabel(_ resetText: String) -> some View {
        Text(resetText)
            .monospacedDigit()
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
