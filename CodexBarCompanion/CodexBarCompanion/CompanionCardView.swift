import SwiftUI

#if canImport(AppKit)
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

enum UsageMenuCardLayout {
    static let horizontalPadding: CGFloat = 20
    static let headerOnlyVerticalPadding: CGFloat = 7
    static let sectionTopPadding: CGFloat = 6
    static let sectionBottomPadding: CGFloat = 6
    static let headerLineSpacing: CGFloat = 4
    static let headerColumnSpacing: CGFloat = 12
}

/// SwiftUI card used inside the NSMenu to mirror Apple's rich menu panels.
struct CompanionCardView: View {


    let model: CompanionCardModel
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    static func popupMetricTitle(metric: CompanionCardModel.Metric) -> String {
        return metric.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageMenuCardHeaderView(model: self.model)

            if self.hasDetails {
                Divider()
            }

            if self.model.metrics.isEmpty {
                if !self.model.usageNotes.isEmpty {
                    UsageNotesContent(notes: self.model.usageNotes)
                } else if let placeholder = self.model.placeholder {
                    Text(placeholder)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .font(.subheadline)
                }
            } else {
                let hasUsage = !self.model.metrics.isEmpty || !self.model.usageNotes.isEmpty
                let hasCredits = self.model.creditsText != nil
                let hasProviderCost = self.model.providerCost != nil
                let hasCost = self.model.tokenUsage != nil || hasProviderCost

                VStack(alignment: .leading, spacing: 12) {
                    if hasUsage {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(self.model.metrics, id: \.id) { metric in
                                MetricRow(
                                    metric: metric,
                                    title: Self.popupMetricTitle(metric: metric),
                                    progressColor: self.model.progressColor)
                            }
                            if !self.model.usageNotes.isEmpty {
                                UsageNotesContent(notes: self.model.usageNotes)
                            }
                        }
                    }
                    if hasUsage, hasCredits || hasCost {
                        Divider()
                    }
                    if let credits = self.model.creditsText {
                        CreditsBarContent(
                            creditsText: credits,
                            creditsRemaining: self.model.creditsRemaining,
                            hintText: self.model.creditsHintText,
                            hintCopyText: self.model.creditsHintCopyText,
                            progressColor: self.model.progressColor)
                    }
                    if hasCredits, hasCost {
                        Divider()
                    }
                    if let providerCost = self.model.providerCost {
                        ProviderCostContent(
                            section: providerCost,
                            progressColor: self.model.progressColor)
                    }
                    if hasProviderCost, self.model.tokenUsage != nil {
                        Divider()
                    }
                    if let tokenUsage = self.model.tokenUsage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("cost_header_estimated"))
                                .font(.body)
                                .fontWeight(.medium)
                            Text(tokenUsage.sessionLine)
                                .font(.footnote)
                            Text(tokenUsage.monthLine)
                                .font(.footnote)
                            if let hint = tokenUsage.hintLine, !hint.isEmpty {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = tokenUsage.errorLine, !error.isEmpty {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.bottom, self.model.creditsText == nil ? 6 : 0)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(
            .top,
            self.hasDetails
                ? UsageMenuCardLayout.sectionTopPadding
                : UsageMenuCardLayout.headerOnlyVerticalPadding)
        .padding(
            .bottom,
            self.hasDetails
                ? UsageMenuCardLayout.sectionBottomPadding
                : UsageMenuCardLayout.headerOnlyVerticalPadding)
        .frame(width: self.width, alignment: .leading)
    }

    private var hasDetails: Bool {
        (!self.model.metrics.isEmpty || !self.model.usageNotes.isEmpty) ||
            self.model.tokenUsage != nil ||
            self.model.providerCost != nil
    }
}

private struct UsageMenuCardHeaderView: View {
    let model: CompanionCardModel
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.model.providerName).font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer()
                Text(self.model.email).font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1).truncationMode(.middle)
            }
            let subtitleAlignment: VerticalAlignment = self.model.subtitleIsError ? .top : .firstTextBaseline
            HStack(alignment: subtitleAlignment, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.model.subtitleText)
                    .font(.footnote)
                    .foregroundStyle(self.subtitleColor)
                    .lineLimit(self.model.subtitleIsError ? 4 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .padding(.bottom, self.model.subtitleIsError ? 4 : 0)
                Spacer()
                if self.model.subtitleIsError, !self.model.subtitleText.isEmpty {
                    CopyIconButton(copyText: self.model.subtitleText, isHighlighted: self.isHighlighted)
                }
                if let plan = self.model.planText {
                    Text(plan)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
    }

    private var subtitleColor: Color {
        self.model.subtitleIsError ? MenuHighlightStyle.error(self.isHighlighted) : MenuHighlightStyle.secondary(self.isHighlighted)
    }
}

private struct CopyIconButtonStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(configuration.isPressed ? 0.18 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CopyIconButton: View {
    let copyText: String
    let isHighlighted: Bool

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            self.copyToPasteboard()
            withAnimation(.easeOut(duration: 0.12)) {
                self.didCopy = true
            }
            self.resetTask?.cancel()
            self.resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                withAnimation(.easeOut(duration: 0.2)) {
                    self.didCopy = false
                }
            }
        } label: {
            Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(CopyIconButtonStyle(isHighlighted: self.isHighlighted))
        .accessibilityLabel(self.didCopy ? L("Copied") : L("Copy error"))
    }

    private func copyToPasteboard() {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(self.copyText, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = self.copyText
        #endif
    }
}

private struct ProviderCostContent: View {
    let section: CompanionCardModel.ProviderCostSection
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.section.title)
                .font(.body)
                .fontWeight(.medium)
            if let percentUsed = self.section.percentUsed {
                UsageProgressBar(
                    percent: percentUsed,
                    tint: self.progressColor,
                    accessibilityLabel: L("Extra usage spent"))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(self.section.spendLine)
                    .font(.footnote)
                Spacer()
                if let percentLine = self.section.percentLine {
                    Text(percentLine)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                }
            }
        }
    }
}

private struct MetricRow: View {
    let metric: CompanionCardModel.Metric
    let title: String
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.title)
                .font(.body)
                .fontWeight(.medium)
            if let statusText = self.metric.statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            } else {
                UsageProgressBar(
                    percent: self.metric.percent,
                    tint: self.progressColor,
                    accessibilityLabel: self.metric.accessibilityLabel,
                    pacePercent: self.metric.pacePercent,
                    paceOnTop: self.metric.paceOnTop,
                    warningMarkerPercents: self.metric.warningMarkerPercents)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(self.metric.percentLabel)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        if let rightLabel = self.metric.resetText {
                            Text(rightLabel)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                .lineLimit(1)
                        }
                    }
                    if self.metric.detailLeftText != nil || self.metric.detailRightText != nil {
                        HStack(alignment: .firstTextBaseline) {
                            if let detailLeft = self.metric.detailLeftText {
                                Text(detailLeft)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let detailRight = self.metric.detailRightText {
                                Text(detailRight)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = self.metric.detailText {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(self.metric.cardStyle ? 10 : 0)
        .background(self.metric.cardStyle ? Color.secondary.opacity(self.isHighlighted ? 0.2 : 0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: self.metric.cardStyle ? 10 : 0))
    }
}

private struct UsageNotesContent: View {
    let notes: [String]
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(self.notes.enumerated()), id: \.offset) { _, note in
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UsageMenuCardHeaderSectionView: View {
    let model: CompanionCardModel
    let showDivider: Bool
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageMenuCardHeaderView(model: self.model)

            if self.showDivider {
                Divider()
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, UsageMenuCardLayout.headerOnlyVerticalPadding)
        .padding(.bottom, self.headerBottomPadding)
        .frame(width: self.width, alignment: .leading)
    }

    private var headerBottomPadding: CGFloat {
        if self.model.subtitleIsError {
            return UsageMenuCardLayout.sectionBottomPadding
        }
        return self.showDivider
            ? UsageMenuCardLayout.sectionBottomPadding
            : UsageMenuCardLayout.headerOnlyVerticalPadding
    }
}

struct UsageMenuCardUsageSectionView: View {
    let model: CompanionCardModel
    let showBottomDivider: Bool
    let bottomPadding: CGFloat
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.model.metrics.isEmpty {
                if !self.model.usageNotes.isEmpty {
                    UsageNotesContent(notes: self.model.usageNotes)
                } else if let placeholder = self.model.placeholder {
                    Text(placeholder)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .font(.subheadline)
                }
            } else {
                ForEach(self.model.metrics, id: \.id) { metric in
                    MetricRow(
                        metric: metric,
                        title: CompanionCardView.popupMetricTitle(metric: metric),
                        progressColor: self.model.progressColor)
                }
                if !self.model.usageNotes.isEmpty {
                    UsageNotesContent(notes: self.model.usageNotes)
                }
            }
            if self.showBottomDivider {
                Divider()
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, self.bottomPadding)
        .frame(width: self.width, alignment: .leading)
    }
}

struct UsageMenuCardCreditsSectionView: View {
    let model: CompanionCardModel
    let showBottomDivider: Bool
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat

    var body: some View {
        if let credits = self.model.creditsText {
            VStack(alignment: .leading, spacing: 6) {
                CreditsBarContent(
                    creditsText: credits,
                    creditsRemaining: self.model.creditsRemaining,
                    hintText: self.model.creditsHintText,
                    hintCopyText: self.model.creditsHintCopyText,
                    progressColor: self.model.progressColor)
                if self.showBottomDivider {
                    Divider()
                }
            }
            .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
            .padding(.top, self.topPadding)
            .padding(.bottom, self.bottomPadding)
            .frame(width: self.width, alignment: .leading)
        }
    }
}

private struct CreditsBarContent: View {
    private static let fullScaleTokens: Double = 1000

    let creditsText: String
    let creditsRemaining: Double?
    let hintText: String?
    let hintCopyText: String?
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    private var percentLeft: Double? {
        guard let creditsRemaining else { return nil }
        let percent = (creditsRemaining / Self.fullScaleTokens) * 100
        return min(100, max(0, percent))
    }

    private var scaleText: String {
        let scale = UsageFormatter.tokenCountString(Int(Self.fullScaleTokens))
        return "\(scale) \(L("tokens"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Credits"))
                .font(.body)
                .fontWeight(.medium)
            if let percentLeft {
                UsageProgressBar(
                    percent: percentLeft,
                    tint: self.progressColor,
                    accessibilityLabel: L("Credits remaining"))
                HStack(alignment: .firstTextBaseline) {
                    Text(self.creditsText)
                        .font(.caption)
                    Spacer()
                    Text(self.scaleText)
                        .font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                }
            } else {
                Text(self.creditsText)
                    .font(.caption)
            }
            if let hintText, !hintText.isEmpty {
                    Text(hintText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UsageMenuCardCostSectionView: View {
    let model: CompanionCardModel
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        let hasTokenCost = self.model.tokenUsage != nil
        return Group {
            if hasTokenCost {
                VStack(alignment: .leading, spacing: 10) {
                    if let tokenUsage = self.model.tokenUsage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("cost_header_estimated"))
                                .font(.body)
                                .fontWeight(.medium)
                            Text(tokenUsage.sessionLine)
                                .font(.caption)
                            Text(tokenUsage.monthLine)
                                .font(.caption)
                            if let hint = tokenUsage.hintLine, !hint.isEmpty {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = tokenUsage.errorLine, !error.isEmpty {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                .padding(.top, self.topPadding)
                .padding(.bottom, self.bottomPadding)
                .frame(width: self.width, alignment: .leading)
            }
        }
    }
}

struct UsageMenuCardExtraUsageSectionView: View {
    let model: CompanionCardModel
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat

    var body: some View {
        Group {
            if let providerCost = self.model.providerCost {
                ProviderCostContent(
                    section: providerCost,
                    progressColor: self.model.progressColor)
                    .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                    .padding(.top, self.topPadding)
                    .padding(.bottom, self.bottomPadding)
                    .frame(width: self.width, alignment: .leading)
            }
        }
    }
}

