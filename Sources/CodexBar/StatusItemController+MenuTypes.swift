import AppKit
import CodexBarCore
import SwiftUI

extension ProviderSwitcherSelection {
    var provider: UsageProvider? {
        switch self {
        case .overview:
            nil
        case let .provider(provider):
            provider
        }
    }
}

struct OverviewMenuCardRowView: View {
    struct LiteSummary: Equatable {
        let title: String
        let primaryText: String
        let secondaryText: String?
        let progressPercent: Double?
        let progressAccessibilityLabel: String?
        let pacePercent: Double?
        let paceOnTop: Bool
        let warningMarkerPercents: [Double]

        @MainActor
        static func make(for model: UsageMenuCardView.Model) -> Self? {
            if let metric = model.metrics.first {
                let primaryText = metric.statusText ?? metric.percentLabel
                let secondaryText = [
                    metric.detailLeftText,
                    metric.detailText,
                    metric.detailRightText,
                    metric.resetText,
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                return Self(
                    title: UsageMenuCardView.popupMetricTitle(provider: model.provider, metric: metric),
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    progressPercent: metric.statusText == nil ? metric.percent : nil,
                    progressAccessibilityLabel: metric.statusText == nil ? metric.percentStyle.accessibilityLabel : nil,
                    pacePercent: metric.statusText == nil ? metric.pacePercent : nil,
                    paceOnTop: metric.paceOnTop,
                    warningMarkerPercents: metric.statusText == nil ? metric.warningMarkerPercents : [])
            }

            if let providerCost = model.providerCost {
                return Self(
                    title: providerCost.title,
                    primaryText: providerCost.percentLine ?? providerCost.spendLine,
                    secondaryText: providerCost.percentLine == nil ? nil : providerCost.spendLine,
                    progressPercent: providerCost.percentUsed,
                    progressAccessibilityLabel: L("Extra usage spent"),
                    pacePercent: nil,
                    paceOnTop: true,
                    warningMarkerPercents: [])
            }

            if let tokenUsage = model.tokenUsage {
                return Self(
                    title: L("cost_header_estimated"),
                    primaryText: tokenUsage.sessionLine,
                    secondaryText: tokenUsage.monthLine,
                    progressPercent: nil,
                    progressAccessibilityLabel: nil,
                    pacePercent: nil,
                    paceOnTop: true,
                    warningMarkerPercents: [])
            }

            if let creditsText = model.creditsText {
                return Self(
                    title: L("Credits"),
                    primaryText: creditsText,
                    secondaryText: model.creditsHintText,
                    progressPercent: nil,
                    progressAccessibilityLabel: nil,
                    pacePercent: nil,
                    paceOnTop: true,
                    warningMarkerPercents: [])
            }

            if let resetCredits = model.codexResetCreditsText {
                return Self(
                    title: L("Credits"),
                    primaryText: resetCredits,
                    secondaryText: model.codexResetCreditsDetailText,
                    progressPercent: nil,
                    progressAccessibilityLabel: nil,
                    pacePercent: nil,
                    paceOnTop: true,
                    warningMarkerPercents: [])
            }

            if let placeholder = model.placeholder {
                return Self(
                    title: L("Usage"),
                    primaryText: placeholder,
                    secondaryText: nil,
                    progressPercent: nil,
                    progressAccessibilityLabel: nil,
                    pacePercent: nil,
                    paceOnTop: true,
                    warningMarkerPercents: [])
            }

            if let note = model.usageNotes.first?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                return Self(
                    title: L("Usage"),
                    primaryText: note,
                    secondaryText: nil,
                    progressPercent: nil,
                    progressAccessibilityLabel: nil,
                    pacePercent: nil,
                    paceOnTop: true,
                    warningMarkerPercents: [])
            }

            return nil
        }
    }

    let model: UsageMenuCardView.Model
    let storageText: String?
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.header(model: self.model, subtitle: self.liveSubtitle)
            if let summary = Self.LiteSummary.make(for: self.model) {
                self.summary(summary, tint: self.model.progressColor)
            }
            if let storageText {
                self.storageLine(storageText)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 8)
        .frame(width: self.width, alignment: .leading)
    }

    var liteSummary: LiteSummary? {
        Self.LiteSummary.make(for: self.model)
    }

    private var liveSubtitle: MenuCardLiveSubtitle {
        let fallback = MenuCardLiveSubtitle(text: self.model.subtitleText, style: self.model.subtitleStyle)
        guard self.model.usesLiveSubtitle else { return fallback }
        return self.refreshMonitor?.subtitle(for: self.model.provider, fallback: fallback) ?? fallback
    }

    private func header(model: UsageMenuCardView.Model, subtitle: MenuCardLiveSubtitle) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(model.providerName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(model.email)
                    .font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(subtitle.text)
                    .font(.footnote)
                    .foregroundStyle(self.subtitleColor(for: subtitle.style))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let plan = model.planText {
                    Text(plan)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private func summary(_ summary: LiteSummary, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(summary.primaryText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let progressPercent = summary.progressPercent,
               let progressAccessibilityLabel = summary.progressAccessibilityLabel
            {
                UsageProgressBar(
                    percent: progressPercent,
                    tint: tint,
                    accessibilityLabel: progressAccessibilityLabel,
                    pacePercent: summary.pacePercent,
                    paceOnTop: summary.paceOnTop,
                    warningMarkerPercents: summary.warningMarkerPercents)
            }
            if let secondaryText = summary.secondaryText {
                Text(secondaryText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func storageLine(_ storageText: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(L("Storage")):")
            Text(storageText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
        .font(.footnote)
        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
    }

    private func subtitleColor(for style: UsageMenuCardView.Model.SubtitleStyle) -> Color {
        switch style {
        case .info: MenuHighlightStyle.secondary(self.isHighlighted)
        case .loading: MenuHighlightStyle.secondary(self.isHighlighted)
        case .error: MenuHighlightStyle.error(self.isHighlighted)
        }
    }
}

struct OpenAIWebMenuItems {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
    let canShowBuyCredits: Bool
}

struct TokenAccountMenuDisplay: Equatable {
    let provider: UsageProvider
    let accounts: [ProviderTokenAccount]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    static func == (lhs: TokenAccountMenuDisplay, rhs: TokenAccountMenuDisplay) -> Bool {
        lhs.provider == rhs.provider &&
            lhs.accountIdentity == rhs.accountIdentity &&
            lhs.activeIndex == rhs.activeIndex &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var accountIdentity: [AccountIdentity] {
        self.accounts.map { account in
            AccountIdentity(
                id: account.id,
                label: account.label,
                externalIdentifier: account.externalIdentifier,
                organizationID: account.organizationID)
        }
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct AccountIdentity: Equatable {
        let id: UUID
        let label: String
        let externalIdentifier: String?
        let organizationID: String?
    }

    private struct SnapshotIdentity: Equatable {
        let id: UUID
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}

struct CodexAccountMenuDisplay: Equatable {
    let accounts: [CodexVisibleAccount]
    let snapshots: [CodexAccountUsageSnapshot]
    let activeVisibleAccountID: String?
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    var workspaceSections: [CodexAccountWorkspaceSection] {
        self.accounts.codexWorkspaceSections()
    }

    var showsWorkspaceGroups: Bool {
        Set(self.workspaceSections.map(\.title)).count > 1
    }

    static func == (lhs: CodexAccountMenuDisplay, rhs: CodexAccountMenuDisplay) -> Bool {
        lhs.accounts == rhs.accounts &&
            lhs.activeVisibleAccountID == rhs.activeVisibleAccountID &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct SnapshotIdentity: Equatable {
        let id: String
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}
