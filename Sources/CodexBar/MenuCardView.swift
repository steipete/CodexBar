import AppKit
import CodexBarCore
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
struct UsageMenuCardView: View {
    struct Model {
        enum PercentStyle: String {
            case left
            case used

            var labelSuffix: String {
                switch self {
                case .left: L("usage_percent_suffix_left")
                case .used: L("usage_percent_suffix_used")
                }
            }

            var accessibilityLabel: String {
                switch self {
                case .left: L("Usage remaining")
                case .used: L("Usage used")
                }
            }
        }

        struct Metric: Identifiable {
            let id: String
            let title: String
            let percent: Double
            let percentStyle: PercentStyle
            let statusText: String?
            let resetText: String?
            let detailText: String?
            let detailLeftText: String?
            let detailRightText: String?
            let pacePercent: Double?
            let paceOnTop: Bool
            let warningMarkerPercents: [Double]
            let cardStyle: Bool

            init(
                id: String,
                title: String,
                percent: Double,
                percentStyle: PercentStyle,
                statusText: String? = nil,
                resetText: String?,
                detailText: String?,
                detailLeftText: String?,
                detailRightText: String?,
                pacePercent: Double?,
                paceOnTop: Bool,
                warningMarkerPercents: [Double] = [],
                cardStyle: Bool = false)
            {
                self.id = id
                self.title = title
                self.percent = percent
                self.percentStyle = percentStyle
                self.statusText = statusText
                self.resetText = resetText
                self.detailText = detailText
                self.detailLeftText = detailLeftText
                self.detailRightText = detailRightText
                self.pacePercent = pacePercent
                self.paceOnTop = paceOnTop
                self.warningMarkerPercents = warningMarkerPercents
                self.cardStyle = cardStyle
            }

            var percentLabel: String {
                String(format: "%.0f%% %@", self.percent, self.percentStyle.labelSuffix)
            }
        }

        enum SubtitleStyle {
            case info
            case loading
            case error
        }

        struct TokenUsageSection {
            let sessionLine: String
            let monthLine: String
            let hintLine: String?
            let errorLine: String?
            let errorCopyText: String?
        }

        struct ProviderCostSection {
            let title: String
            let percentUsed: Double?
            let spendLine: String
            let percentLine: String?
        }

        let provider: UsageProvider
        let providerName: String
        let email: String
        let subtitleText: String
        let subtitleStyle: SubtitleStyle
        let planText: String?
        let metrics: [Metric]
        let usageNotes: [String]
        let openAIAPIUsage: OpenAIAPIUsageSnapshot?
        let inlineUsageDashboard: InlineUsageDashboardModel?
        let creditsText: String?
        let creditsRemaining: Double?
        let creditsHintText: String?
        let creditsHintCopyText: String?
        let providerCost: ProviderCostSection?
        let tokenUsage: TokenUsageSection?
        let placeholder: String?
        let progressColor: Color
    }

    let model: Model
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    static func popupMetricTitle(provider: UsageProvider, metric: Model.Metric) -> String {
        if provider == .openrouter, metric.id == "primary" {
            return L("API key limit")
        }
        return metric.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageMenuCardHeaderView(model: self.model)

            if self.hasDetails {
                Divider()
            }

            if !self.model.usesStackedDetailLayout {
                if let dashboard = self.model.inlineUsageDashboard {
                    InlineUsageDashboardContent(model: dashboard)
                } else if !self.model.usageNotes.isEmpty {
                    UsageNotesContent(notes: self.model.usageNotes)
                } else if let placeholder = self.model.placeholder {
                    Text(placeholder)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .font(.subheadline)
                }
            } else {
                let hasUsage = self.model.hasUsageContent
                let hasCredits = self.model.creditsText != nil
                let hasProviderCost = self.model.providerCost != nil
                let hasCost = self.model.tokenUsage != nil || hasProviderCost

                VStack(alignment: .leading, spacing: 12) {
                    if hasUsage {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(self.model.metrics, id: \.id) { metric in
                                MetricRow(
                                    metric: metric,
                                    title: Self.popupMetricTitle(provider: self.model.provider, metric: metric),
                                    progressColor: self.model.progressColor)
                            }
                            if let dashboard = self.model.inlineUsageDashboard {
                                InlineUsageDashboardContent(model: dashboard)
                            } else if !self.model.usageNotes.isEmpty {
                                UsageNotesContent(notes: self.model.usageNotes)
                            } else if let placeholder = self.model.placeholder {
                                Text(placeholder)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .font(.subheadline)
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
                                    .overlay {
                                        ClickToCopyOverlay(copyText: tokenUsage.errorCopyText ?? error)
                                    }
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
        self.model.hasUsageContent || self.model.usesStackedDetailLayout
    }
}

private struct UsageMenuCardHeaderView: View {
    let model: UsageMenuCardView.Model
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
            let subtitleAlignment: VerticalAlignment = self.model.subtitleStyle == .error ? .top : .firstTextBaseline
            HStack(alignment: subtitleAlignment, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.model.subtitleText)
                    .font(.footnote)
                    .foregroundStyle(self.subtitleColor)
                    .lineLimit(self.model.subtitleStyle == .error ? 4 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .padding(.bottom, self.model.subtitleStyle == .error ? 4 : 0)
                Spacer()
                if self.model.subtitleStyle == .error, !self.model.subtitleText.isEmpty {
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
        switch self.model.subtitleStyle {
        case .info: MenuHighlightStyle.secondary(self.isHighlighted)
        case .loading: MenuHighlightStyle.secondary(self.isHighlighted)
        case .error: MenuHighlightStyle.error(self.isHighlighted)
        }
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
            self.handleCopy()
        } label: {
            Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(CopyIconButtonStyle(isHighlighted: self.isHighlighted))
        .accessibilityLabel(self.didCopy ? L("Copied") : L("Copy error"))
    }

    private func handleCopy() {
        let text = self.copyText
        self.resetTask?.cancel()
        MenuPasteboardCopy.perform(text, completion: {
            self.didCopy = true
            self.resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                self.didCopy = false
            }
        })
    }
}

private struct ProviderCostContent: View {
    let section: UsageMenuCardView.Model.ProviderCostSection
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
    let metric: UsageMenuCardView.Model.Metric
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
                    accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
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
    let model: UsageMenuCardView.Model
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
        if self.model.subtitleStyle == .error {
            return UsageMenuCardLayout.sectionBottomPadding
        }
        return self.showDivider
            ? UsageMenuCardLayout.sectionBottomPadding
            : UsageMenuCardLayout.headerOnlyVerticalPadding
    }
}

struct UsageMenuCardUsageSectionView: View {
    let model: UsageMenuCardView.Model
    let showBottomDivider: Bool
    let bottomPadding: CGFloat
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.model.metrics.isEmpty {
                if let dashboard = self.model.inlineUsageDashboard {
                    InlineUsageDashboardContent(model: dashboard)
                } else if !self.model.usageNotes.isEmpty {
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
                        title: UsageMenuCardView.popupMetricTitle(provider: self.model.provider, metric: metric),
                        progressColor: self.model.progressColor)
                }
                if let dashboard = self.model.inlineUsageDashboard {
                    InlineUsageDashboardContent(model: dashboard)
                } else if !self.model.usageNotes.isEmpty {
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
    let model: UsageMenuCardView.Model
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
                    .overlay {
                        ClickToCopyOverlay(copyText: self.hintCopyText ?? hintText)
                    }
            }
        }
    }
}

struct UsageMenuCardCostSectionView: View {
    let model: UsageMenuCardView.Model
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
                                    .overlay {
                                        ClickToCopyOverlay(copyText: tokenUsage.errorCopyText ?? error)
                                    }
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
    let model: UsageMenuCardView.Model
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

// MARK: - Model factory

extension UsageMenuCardView.Model {
    struct Input {
        let provider: UsageProvider
        let metadata: ProviderMetadata
        let snapshot: UsageSnapshot?
        let codexProjection: CodexConsumerProjection?
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        let account: AccountInfo
        let isRefreshing: Bool
        let lastError: String?
        let usageBarsShowUsed: Bool
        let resetTimeDisplayStyle: ResetTimeDisplayStyle
        let tokenCostUsageEnabled: Bool
        let showOptionalCreditsAndExtraUsage: Bool
        let sourceLabel: String?
        let kiloAutoMode: Bool
        let hidePersonalInfo: Bool
        let weeklyPace: UsagePace?
        let quotaWarningThresholds: [QuotaWarningWindow: [Int]]
        let workDaysPerWeek: Int?
        let now: Date

        init(
            provider: UsageProvider,
            metadata: ProviderMetadata,
            snapshot: UsageSnapshot?,
            codexProjection: CodexConsumerProjection? = nil,
            credits: CreditsSnapshot?,
            creditsError: String?,
            dashboard: OpenAIDashboardSnapshot?,
            dashboardError: String?,
            tokenSnapshot: CostUsageTokenSnapshot?,
            tokenError: String?,
            account: AccountInfo,
            isRefreshing: Bool,
            lastError: String?,
            usageBarsShowUsed: Bool,
            resetTimeDisplayStyle: ResetTimeDisplayStyle,
            tokenCostUsageEnabled: Bool,
            showOptionalCreditsAndExtraUsage: Bool,
            sourceLabel: String? = nil,
            kiloAutoMode: Bool = false,
            hidePersonalInfo: Bool,
            weeklyPace: UsagePace? = nil,
            quotaWarningThresholds: [QuotaWarningWindow: [Int]] = [:],
            workDaysPerWeek: Int? = nil,
            now: Date)
        {
            self.provider = provider
            self.metadata = metadata
            self.snapshot = snapshot
            self.codexProjection = codexProjection
            self.credits = credits
            self.creditsError = creditsError
            self.dashboard = dashboard
            self.dashboardError = dashboardError
            self.tokenSnapshot = tokenSnapshot
            self.tokenError = tokenError
            self.account = account
            self.isRefreshing = isRefreshing
            self.lastError = lastError
            self.usageBarsShowUsed = usageBarsShowUsed
            self.resetTimeDisplayStyle = resetTimeDisplayStyle
            self.tokenCostUsageEnabled = tokenCostUsageEnabled
            self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
            self.sourceLabel = sourceLabel
            self.kiloAutoMode = kiloAutoMode
            self.hidePersonalInfo = hidePersonalInfo
            self.weeklyPace = weeklyPace
            self.quotaWarningThresholds = quotaWarningThresholds
            self.workDaysPerWeek = workDaysPerWeek
            self.now = now
        }
    }

    static func make(_ input: Input) -> UsageMenuCardView.Model {
        let planText = Self.plan(
            for: input.provider,
            snapshot: input.snapshot,
            account: input.account,
            metadata: input.metadata)
        let metrics = Self.metrics(input: input)
        let openAIAPIUsage = input.snapshot?.openAIAPIUsage
        let inlineUsageDashboard = Self.inlineUsageDashboard(input: input)
        let usageNotes = Self.usageNotes(input: input)
        let creditsText: String? = if input.provider == .openrouter {
            nil
        } else if input.codexProjection != nil, !input.showOptionalCreditsAndExtraUsage {
            nil
        } else {
            Self.creditsLine(metadata: input.metadata, credits: input.credits, error: input.creditsError)
        }
        let isClaudeAdminAPI = input.provider == .claude &&
            input.snapshot?.identity?.loginMethod == "Admin API"
        let hidesOptionalProviderCost = ((input.provider == .claude && !isClaudeAdminAPI) ||
            input.provider == .factory ||
            input.provider == .opencodego) &&
            !input.showOptionalCreditsAndExtraUsage
        let providerCost: ProviderCostSection? = if hidesOptionalProviderCost ||
            (input.provider == .openai && openAIAPIUsage != nil)
        {
            nil
        } else {
            Self.providerCostSection(provider: input.provider, cost: input.snapshot?.providerCost)
        }
        let tokenUsageSnapshot = Self.tokenUsageSnapshot(input: input)
        let tokenUsage = Self.tokenUsageSection(
            provider: input.provider,
            enabled: input.tokenCostUsageEnabled,
            snapshot: tokenUsageSnapshot,
            error: input.tokenError)
        let subtitle = Self.subtitle(
            snapshot: input.snapshot,
            isRefreshing: input.isRefreshing,
            lastError: Self.lastError(input: input),
            now: input.now)
        let redacted = Self.redactedText(input: input, subtitle: subtitle)
        let placeholder = Self.placeholder(input: input)

        return UsageMenuCardView.Model(
            provider: input.provider,
            providerName: input.metadata.displayName,
            email: redacted.email,
            subtitleText: redacted.subtitleText,
            subtitleStyle: subtitle.style,
            planText: planText,
            metrics: metrics,
            usageNotes: usageNotes,
            openAIAPIUsage: openAIAPIUsage,
            inlineUsageDashboard: inlineUsageDashboard,
            creditsText: creditsText,
            creditsRemaining: input.credits?.remaining,
            creditsHintText: redacted.creditsHintText,
            creditsHintCopyText: redacted.creditsHintCopyText,
            providerCost: providerCost,
            tokenUsage: tokenUsage,
            placeholder: placeholder,
            progressColor: Self.progressColor(for: input.provider))
    }

    private static func usageNotes(input: Input) -> [String] {
        let subscriptionNotes = self.subscriptionMetadataNotes(snapshot: input.snapshot, provider: input.provider)

        if input.provider == .kiro {
            return kiroUsageNotes(input: input) + subscriptionNotes
        }

        if input.provider == .kilo {
            var notes = Self.kiloLoginDetails(snapshot: input.snapshot)
            let resolvedSource = input.sourceLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if input.kiloAutoMode,
               resolvedSource == "cli",
               !notes.contains(where: { $0.caseInsensitiveCompare("Using CLI fallback") == .orderedSame })
            {
                notes.append(L("Using CLI fallback"))
            }
            return notes + subscriptionNotes
        }

        if input.provider == .mimo, input.snapshot != nil {
            return [
                L("Balance updates in near-real time (up to 5 min lag)"),
                L("Daily billing data finalizes at 07:00 UTC"),
            ] + subscriptionNotes
        }

        if let notes = apiProviderUsageNotes(input: input) {
            return notes + subscriptionNotes
        }

        guard input.provider == .openrouter,
              let openRouter = input.snapshot?.openRouterUsage
        else {
            return subscriptionNotes
        }

        var notes = Self.openRouterSpendNotes(openRouter)
        switch openRouter.keyQuotaStatus {
        case .available:
            break
        case .noLimitConfigured:
            notes.append(L("No limit set for the API key"))
        case .unavailable:
            notes.append(L("API key limit unavailable right now"))
        }
        return notes + subscriptionNotes
    }

    private static func subscriptionMetadataNotes(snapshot: UsageSnapshot?, provider: UsageProvider) -> [String] {
        guard let snapshot else { return [] }
        if let renewsAt = snapshot.subscriptionRenewsAt {
            return [String(format: L("Renews: %@"), self.subscriptionDateString(renewsAt, provider: provider))]
        }
        if let expiresAt = snapshot.subscriptionExpiresAt {
            return [String(format: L("Plan expires: %@"), self.subscriptionDateString(expiresAt, provider: provider))]
        }
        return []
    }

    private static func subscriptionDateString(_ date: Date, provider: UsageProvider) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = self.subscriptionDateTimeZone(provider: provider)
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter.string(from: date)
    }

    private static func subscriptionDateTimeZone(provider: UsageProvider) -> TimeZone {
        switch provider {
        case .minimax:
            TimeZone(identifier: "Asia/Shanghai") ?? .current
        default:
            .current
        }
    }

    private static func openRouterSpendNotes(_ usage: OpenRouterUsageSnapshot) -> [String] {
        var parts: [String] = []
        if let daily = usage.keyUsageDaily {
            parts.append("\(L("Today")): \(Self.openRouterCurrencyString(daily))")
        }
        if let weekly = usage.keyUsageWeekly {
            parts.append("\(L("This week")): \(Self.openRouterCurrencyString(weekly))")
        }
        guard !parts.isEmpty else { return [] }
        return [parts.joined(separator: " · ")]
    }

    private static func openRouterCurrencyString(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func email(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo,
        metadata: ProviderMetadata) -> String
    {
        if let email = snapshot?.accountEmail(for: provider), !email.isEmpty { return email }
        if metadata.usesAccountFallback,
           let email = account.email, !email.isEmpty
        {
            return email
        }
        return ""
    }

    private static func plan(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo,
        metadata: ProviderMetadata) -> String?
    {
        if provider == .kiro,
           let plan = kiroPlan(snapshot: snapshot)
        {
            return plan
        }
        if provider == .kilo {
            guard let pass = self.kiloLoginPass(snapshot: snapshot) else {
                return nil
            }
            return self.planDisplay(pass, for: provider)
        }
        if let plan = snapshot?.loginMethod(for: provider), !plan.isEmpty {
            return self.planDisplay(plan, for: provider)
        }
        if metadata.usesAccountFallback,
           let plan = account.plan, !plan.isEmpty
        {
            return Self.planDisplay(plan, for: provider)
        }
        return nil
    }

    private static func planDisplay(_ text: String, for provider: UsageProvider) -> String {
        if provider == .minimax {
            return self.miniMaxPlanDisplay(text)
        }
        let cleaned = if provider == .codex {
            CodexPlanFormatting.displayName(text) ?? UsageFormatter.cleanPlanName(text)
        } else {
            UsageFormatter.cleanPlanName(text)
        }
        return cleaned.isEmpty ? text : cleaned
    }

    private static func miniMaxPlanDisplay(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized.contains("tokenplanplus") || normalized.contains("token plan plus") {
            return "Plus"
        }
        if normalized.contains("tokenplanmax") || normalized.contains("token plan max") {
            return "Max"
        }
        if normalized.contains("tokenplanultra") || normalized.contains("token plan ultra") {
            return "Ultra"
        }
        return trimmed
    }

    private static func kiloLoginPass(snapshot: UsageSnapshot?) -> String? {
        self.kiloLoginParts(snapshot: snapshot).pass
    }

    private static func kiloLoginDetails(snapshot: UsageSnapshot?) -> [String] {
        self.kiloLoginParts(snapshot: snapshot).details
    }

    private static func kiloLoginParts(snapshot: UsageSnapshot?) -> (pass: String?, details: [String]) {
        guard let loginMethod = snapshot?.loginMethod(for: .kilo) else {
            return (nil, [])
        }
        let parts = loginMethod
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return (nil, [])
        }
        let first = parts[0]
        if self.isKiloActivitySegment(first) {
            return (nil, parts)
        }
        return (first, Array(parts.dropFirst()))
    }

    private static func isKiloActivitySegment(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("auto top-up:")
    }

    private static func subtitle(
        snapshot: UsageSnapshot?,
        isRefreshing: Bool,
        lastError: String?,
        now: Date) -> (text: String, style: SubtitleStyle)
    {
        if let lastError, !lastError.isEmpty {
            return (lastError.trimmingCharacters(in: .whitespacesAndNewlines), .error)
        }

        if isRefreshing, snapshot == nil {
            return ("\(L("Refreshing"))…", .loading)
        }

        if let updated = snapshot?.updatedAt {
            return (UsageFormatter.updatedString(from: updated, now: now), .info)
        }

        return (L("Not fetched yet"), .info)
    }

    private struct RedactedText {
        let email: String
        let subtitleText: String
        let creditsHintText: String?
        let creditsHintCopyText: String?
    }

    private static func redactedText(
        input: Input,
        subtitle: (text: String, style: SubtitleStyle)) -> RedactedText
    {
        let email = PersonalInfoRedactor.redactEmail(
            Self.email(
                for: input.provider,
                snapshot: input.snapshot,
                account: input.account,
                metadata: input.metadata),
            isEnabled: input.hidePersonalInfo)
        let subtitleText = PersonalInfoRedactor.redactEmails(in: subtitle.text, isEnabled: input.hidePersonalInfo)
            ?? subtitle.text
        let creditsHintText = PersonalInfoRedactor.redactEmails(
            in: Self.dashboardHint(error: input.dashboardError),
            isEnabled: input.hidePersonalInfo)
        let creditsHintCopyText = Self.creditsHintCopyText(
            dashboardError: input.dashboardError,
            hidePersonalInfo: input.hidePersonalInfo)
        return RedactedText(
            email: email,
            subtitleText: subtitleText,
            creditsHintText: creditsHintText,
            creditsHintCopyText: creditsHintCopyText)
    }

    private static func creditsHintCopyText(dashboardError: String?, hidePersonalInfo: Bool) -> String? {
        guard let dashboardError, !dashboardError.isEmpty else { return nil }
        return hidePersonalInfo ? "" : dashboardError
    }

    private static func metrics(input: Input) -> [Metric] {
        guard let snapshot = input.snapshot else { return [] }
        if input.provider == .antigravity {
            return Self.antigravityMetrics(input: input, snapshot: snapshot)
        }
        if input.provider == .minimax {
            if let minimaxUsage = snapshot.minimaxUsage {
                let services = minimaxUsage.orderedQuotaServices
                if !services.isEmpty {
                    return Self.minimaxMetrics(services: services, input: input)
                }
            }
        }
        var metrics: [Metric] = []
        let percentStyle: PercentStyle = input.usageBarsShowUsed ? .used : .left
        let zaiUsage = input.provider == .zai ? snapshot.zaiUsage : nil
        let zaiTokenDetail = Self.zaiLimitDetailText(limit: zaiUsage?.tokenLimit)
        let zaiTimeDetail = Self.zaiLimitDetailText(limit: zaiUsage?.timeLimit)
        let zaiSessionDetail = Self.zaiLimitDetailText(limit: zaiUsage?.sessionTokenLimit)
        let openRouterQuotaDetail = Self.openRouterQuotaDetail(provider: input.provider, snapshot: snapshot)
        let labels = Self.rateWindowLabels(input: input, snapshot: snapshot)
        if input.provider == .codex, let codexProjection = input.codexProjection {
            metrics.append(contentsOf: Self.codexRateMetrics(
                input: input,
                projection: codexProjection,
                percentStyle: percentStyle))
        } else if let primary = snapshot.primary {
            metrics.append(Self.primaryMetric(
                input: input,
                primary: primary,
                percentStyle: percentStyle,
                title: labels.primary,
                zaiTokenDetail: zaiTokenDetail,
                openRouterQuotaDetail: openRouterQuotaDetail))
        }
        if input.provider != .codex, let weekly = snapshot.secondary {
            metrics.append(Self.secondaryMetric(
                input: input,
                weekly: weekly,
                percentStyle: percentStyle,
                title: labels.secondary,
                zaiTimeDetail: zaiTimeDetail))
        }
        if labels.showsTertiary, let opus = snapshot.tertiary {
            var tertiaryDetailText: String?
            if input.provider == .alibaba || input.provider == .alibabatokenplan,
               let detail = opus.resetDescription,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                tertiaryDetailText = detail
            }
            if input.provider == .zai, let detail = zaiSessionDetail {
                tertiaryDetailText = detail
            }
            // Perplexity purchased credits don't reset; show balance without "Resets" prefix.
            let opusResetText: String? = input.provider == .perplexity
                ? opus.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                : Self.resetText(for: opus, style: input.resetTimeDisplayStyle, now: input.now)
            let tertiaryPaceDetail = Self.cursorBillingCyclePaceDetail(window: opus, input: input)
            metrics.append(Metric(
                id: "tertiary",
                title: labels.tertiary,
                percent: Self.clamped(input.usageBarsShowUsed ? opus.usedPercent : opus.remainingPercent),
                percentStyle: percentStyle,
                resetText: opusResetText,
                detailText: tertiaryDetailText,
                detailLeftText: tertiaryPaceDetail?.leftLabel,
                detailRightText: tertiaryPaceDetail?.rightLabel,
                pacePercent: tertiaryPaceDetail?.pacePercent,
                paceOnTop: tertiaryPaceDetail?.paceOnTop ?? true,
                warningMarkerPercents: Self.warningMarkerPercents(
                    thresholds: input.quotaWarningThresholds[.weekly],
                    showUsed: input.usageBarsShowUsed)))
        }
        metrics.append(contentsOf: Self.extraRateWindowMetrics(
            snapshot: snapshot,
            input: input,
            percentStyle: percentStyle))
        if input.provider == .kilo,
           metrics.contains(where: { $0.id == "primary" }),
           metrics.contains(where: { $0.id == "secondary" })
        {
            metrics.sort { lhs, rhs in
                let kiloOrder: [String: Int] = [
                    "secondary": 0,
                    "primary": 1,
                ]
                return (kiloOrder[lhs.id] ?? Int.max) < (kiloOrder[rhs.id] ?? Int.max)
            }
        }

        if let codexProjection = input.codexProjection,
           codexProjection.supplementalMetrics.contains(.codeReview),
           let remaining = codexProjection.remainingPercent(for: .codeReview)
        {
            let percent = input.usageBarsShowUsed ? (100 - remaining) : remaining
            let resetText = codexProjection.limitWindow(for: .codeReview).flatMap {
                Self.resetText(for: $0, style: input.resetTimeDisplayStyle, now: input.now)
            }
            metrics.append(Metric(
                id: "code-review",
                title: L("Code review"),
                percent: Self.clamped(percent),
                percentStyle: percentStyle,
                resetText: resetText,
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true))
        }
        return metrics
    }

    private static func rateWindowLabels(
        input: Input,
        snapshot: UsageSnapshot) -> (primary: String, secondary: String, tertiary: String, showsTertiary: Bool)
    {
        if input.provider == .factory, snapshot.tertiary != nil {
            return ("5-hour", L("Weekly"), L("Monthly"), true)
        }
        let primaryLabel = input.provider == .grok
            ? GrokProviderDescriptor.primaryLabel(window: snapshot.primary) ?? input.metadata.sessionLabel
            : input.metadata.sessionLabel
        return (
            L(primaryLabel),
            L(input.metadata.weeklyLabel),
            input.metadata.opusLabel.map(L) ?? L("Sonnet"),
            input.metadata.supportsOpus)
    }

    private static func primaryMetric(
        input: Input,
        primary: RateWindow,
        percentStyle: PercentStyle,
        title: String? = nil,
        zaiTokenDetail: String?,
        openRouterQuotaDetail: String?) -> Metric
    {
        var primaryDetailText: String? = input.provider == .zai ? zaiTokenDetail : nil
        var primaryResetText = Self.resetText(for: primary, style: input.resetTimeDisplayStyle, now: input.now)
        var primaryDetailLeft: String?
        var primaryDetailRight: String?
        if input.provider == .crof,
           let detail = primary.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty
        {
            primaryDetailRight = detail
        }
        if input.provider == .openrouter,
           let openRouterQuotaDetail
        {
            primaryResetText = openRouterQuotaDetail
        }
        if input.provider == .copilot,
           let detail = primary.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty
        {
            primaryDetailLeft = detail
        }
        if input.provider == .warp || input.provider == .kilo || input.provider == .mimo || input.provider == .deepseek,
           let detail = primary.resetDescription,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            primaryDetailText = detail
        }
        if input.provider == .kiro,
           let kiroUsage = input.snapshot?.kiroUsage,
           kiroUsage.creditsTotal > 0
        {
            let remaining = UsageFormatter.kiroCreditNumber(kiroUsage.creditsRemaining)
            let total = UsageFormatter.kiroCreditNumber(kiroUsage.creditsTotal)
            primaryDetailLeft = String(format: L("%@ of %@ credits left"), remaining, total)
        }
        if input.provider == .alibaba || input.provider == .alibabatokenplan || input.provider == .mistral || input
            .provider == .manus,
            let detail = primary.resetDescription,
            !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            primaryDetailText = detail
            if input.provider == .manus { primaryResetText = nil }
        }
        if [.warp, .kilo, .mimo, .deepseek].contains(input.provider), primary.resetsAt == nil {
            primaryResetText = nil
        }
        // Abacus: show credits as detail, compute pace on the primary monthly window
        var primaryPacePercent: Double?
        var primaryPaceOnTop = true
        if let paceDetail = Self.sessionPaceDetail(
            provider: input.provider,
            window: primary,
            now: input.now,
            showUsed: input.usageBarsShowUsed)
        {
            primaryDetailLeft = paceDetail.leftLabel
            primaryDetailRight = paceDetail.rightLabel
            primaryPacePercent = paceDetail.pacePercent
            primaryPaceOnTop = paceDetail.paceOnTop
        }
        if input.provider == .abacus {
            if let detail = primary.resetDescription,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                primaryDetailText = detail
            }
            if primary.resetsAt == nil {
                primaryResetText = nil
            }
            if let pace = input.weeklyPace {
                let paceDetail = Self.weeklyPaceDetail(
                    window: primary,
                    now: input.now,
                    pace: pace,
                    showUsed: input.usageBarsShowUsed)
                if let paceDetail {
                    primaryDetailLeft = paceDetail.leftLabel
                    primaryDetailRight = paceDetail.rightLabel
                    primaryPacePercent = paceDetail.pacePercent
                    primaryPaceOnTop = paceDetail.paceOnTop
                }
            }
        }
        if let paceDetail = Self.cursorBillingCyclePaceDetail(window: primary, input: input) {
            primaryDetailLeft = paceDetail.leftLabel
            primaryDetailRight = paceDetail.rightLabel
            primaryPacePercent = paceDetail.pacePercent
            primaryPaceOnTop = paceDetail.paceOnTop
        }
        if input.provider == .synthetic,
           let regen = Self.syntheticRollingRegenDetail(
               window: primary,
               now: input.now,
               showUsed: input.usageBarsShowUsed)
        {
            primaryResetText = regen.resetText
            primaryDetailLeft = regen.pace.leftLabel
            primaryDetailRight = regen.pace.rightLabel
            primaryPacePercent = regen.pace.pacePercent
            primaryPaceOnTop = regen.pace.paceOnTop
        }
        let primaryStatusText = input.provider == .deepseek ? primaryDetailText : nil
        if input.provider == .deepseek {
            primaryDetailText = nil
        }
        return Metric(
            id: "primary",
            title: title ?? L(input.metadata.sessionLabel),
            percent: Self.clamped(
                input.usageBarsShowUsed ? primary.usedPercent : primary.remainingPercent),
            percentStyle: percentStyle,
            statusText: primaryStatusText,
            resetText: primaryResetText,
            detailText: primaryDetailText,
            detailLeftText: primaryDetailLeft,
            detailRightText: primaryDetailRight,
            pacePercent: primaryPacePercent,
            paceOnTop: primaryPaceOnTop,
            warningMarkerPercents: Self.warningMarkerPercents(
                thresholds: input.quotaWarningThresholds[.session],
                showUsed: input.usageBarsShowUsed))
    }

    private static func secondaryMetric(
        input: Input,
        weekly: RateWindow,
        percentStyle: PercentStyle,
        title: String? = nil,
        zaiTimeDetail: String?) -> Metric
    {
        var paceDetail = Self.weeklyPaceDetail(
            window: weekly,
            now: input.now,
            pace: input.weeklyPace,
            showUsed: input.usageBarsShowUsed)
        var weeklyResetText = Self.resetText(for: weekly, style: input.resetTimeDisplayStyle, now: input.now)
        var weeklyDetailText: String? = input.provider == .zai ? zaiTimeDetail : nil
        if input.provider == .warp,
           let detail = weekly.resetDescription,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            weeklyResetText = nil
            weeklyDetailText = detail
        }
        if input.provider == .kilo,
           let detail = weekly.resetDescription,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            weeklyDetailText = detail
            if weekly.resetsAt == nil {
                weeklyResetText = nil
            }
        }
        if input.provider == .kiro,
           let kiroUsage = input.snapshot?.kiroUsage,
           let remaining = kiroUsage.bonusCreditsRemaining,
           let total = kiroUsage.bonusCreditsTotal
        {
            let remainingText = UsageFormatter.kiroCreditNumber(remaining)
            let totalText = UsageFormatter.kiroCreditNumber(total)
            paceDetail = PaceDetail(
                leftLabel: String(format: L("%@ of %@ bonus credits left"), remainingText, totalText),
                rightLabel: nil,
                pacePercent: nil,
                paceOnTop: true)
        }
        if input.provider == .alibaba || input.provider == .alibabatokenplan,
           let detail = weekly.resetDescription,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            weeklyDetailText = detail
        }
        if input.provider == .manus,
           let detail = weekly.resetDescription,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            weeklyDetailText = detail
        }
        if input.provider == .crof,
           let detail = weekly.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty
        {
            weeklyResetText = detail
        }
        if input.provider == .copilot,
           let detail = weekly.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty
        {
            paceDetail = PaceDetail(leftLabel: detail, rightLabel: nil, pacePercent: nil, paceOnTop: true)
        }
        if let cursorPaceDetail = Self.cursorBillingCyclePaceDetail(
            window: weekly,
            input: input,
            pace: input.weeklyPace)
        {
            paceDetail = cursorPaceDetail
        }
        // Perplexity bonus credits don't reset; show balance without "Resets" prefix.
        if input.provider == .perplexity,
           let detail = weekly.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty
        {
            weeklyResetText = detail
        }
        if input.provider == .synthetic,
           let regen = Self.syntheticRegenDetail(
               weekly: weekly,
               cost: input.snapshot?.providerCost,
               now: input.now,
               showUsed: input.usageBarsShowUsed)
        {
            weeklyResetText = regen.resetText
            paceDetail = regen.pace
        }
        return Metric(
            id: "secondary",
            title: title ?? L(input.metadata.weeklyLabel),
            percent: Self.clamped(input.usageBarsShowUsed ? weekly.usedPercent : weekly.remainingPercent),
            percentStyle: percentStyle,
            resetText: weeklyResetText,
            detailText: weeklyDetailText,
            detailLeftText: paceDetail?.leftLabel,
            detailRightText: paceDetail?.rightLabel,
            pacePercent: paceDetail?.pacePercent,
            paceOnTop: paceDetail?.paceOnTop ?? true,
            warningMarkerPercents: Self.weeklyMarkerPercents(input: input, windowMinutes: weekly.windowMinutes))
    }

    private static func codexRateMetrics(
        input: Input,
        projection: CodexConsumerProjection,
        percentStyle: PercentStyle) -> [Metric]
    {
        projection.visibleRateLanes.compactMap { lane in
            guard let window = projection.rateWindow(for: lane) else { return nil }

            let title: String
            let id: String
            let paceDetail: PaceDetail?
            switch lane {
            case .session:
                title = L(input.metadata.sessionLabel)
                id = "primary"
                paceDetail = Self.sessionPaceDetail(
                    provider: input.provider,
                    window: window,
                    now: input.now,
                    showUsed: input.usageBarsShowUsed)
            case .weekly:
                title = L(input.metadata.weeklyLabel)
                id = "secondary"
                paceDetail = Self.weeklyPaceDetail(
                    window: window,
                    now: input.now,
                    pace: input.weeklyPace
                        ?? UsagePace.weekly(window: window, now: input.now, defaultWindowMinutes: 10080)
                        .flatMap { $0.expectedUsedPercent >= 3 ? $0 : nil },
                    showUsed: input.usageBarsShowUsed)
            }

            return Metric(
                id: id,
                title: title,
                percent: Self.clamped(input.usageBarsShowUsed ? window.usedPercent : window.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: window, style: input.resetTimeDisplayStyle, now: input.now),
                detailText: nil,
                detailLeftText: paceDetail?.leftLabel,
                detailRightText: paceDetail?.rightLabel,
                pacePercent: paceDetail?.pacePercent,
                paceOnTop: paceDetail?.paceOnTop ?? true,
                warningMarkerPercents: Self.codexLaneMarkerPercents(
                    input: input,
                    lane: lane,
                    windowMinutes: window.windowMinutes))
        }
    }

    private static func dashboardHint(error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        return error
    }
}
