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
    var isCriticallyLow = false

    var body: some View {
        if let layoutResetText {
            // NSMenu freezes the hosted row height while tracking. Measure the warning's worst-case
            // wrapping, but let healthy visible content use the full title width independently.
            self.adaptiveHeader(title: self.layoutTitle, resetText: layoutResetText, showsWarning: true)
                .hidden()
                .overlay(alignment: .topLeading) {
                    self.visibleContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .clipped()
        } else {
            self.visibleContent
        }
    }

    @ViewBuilder
    var visibleContent: some View {
        if let layoutResetText {
            self.liveHeader(title: self.title, resetText: self.resetText ?? layoutResetText)
        } else {
            self.titleLabel(self.title, showsWarning: self.isCriticallyLow)
        }
    }

    private func adaptiveHeader(title: String, resetText: String, showsWarning: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            self.horizontalHeader(title: title, resetText: resetText, showsWarning: showsWarning)
            self.verticalHeader(title: title, resetText: resetText, showsWarning: showsWarning)
        }
    }

    /// Live strings can outgrow the frozen template. The overlay proposes the template's height, so only stack
    /// when that height allows it; otherwise stay on one row and shorten the title rather than clip the reset line.
    private func liveHeader(title: String, resetText: String) -> some View {
        ViewThatFits(in: .horizontal) {
            self.horizontalHeader(title: title, resetText: resetText, showsWarning: self.isCriticallyLow)
            ViewThatFits(in: .vertical) {
                self.verticalHeader(title: title, resetText: resetText, showsWarning: self.isCriticallyLow)
                self.compressedHeader(title: title, resetText: resetText)
            }
        }
    }

    private func compressedHeader(title: String, resetText: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            self.titleLabel(title, showsWarning: self.isCriticallyLow)
            Spacer(minLength: 8)
            self.resetLabel(resetText, lineLimit: 1)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func horizontalHeader(title: String, resetText: String, showsWarning: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            self.titleLabel(title, showsWarning: showsWarning)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            self.resetLabel(resetText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verticalHeader(title: String, resetText: String, showsWarning: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            self.titleLabel(title, showsWarning: showsWarning)
                .frame(maxWidth: .infinity, alignment: .leading)
            self.resetLabel(resetText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func titleLabel(_ title: String, showsWarning: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                    .accessibilityLabel(L("quota_warning_critical"))
            }
        }
    }

    private func resetLabel(_ resetText: String, lineLimit: Int = 2) -> some View {
        Text(resetText)
            .font(.footnote)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .lineLimit(lineLimit)
            .multilineTextAlignment(.trailing)
    }
}
