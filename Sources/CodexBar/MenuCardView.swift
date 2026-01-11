import AppKit
import CodexBarCore
import SwiftUI

/// SwiftUI card used inside the NSMenu to mirror Apple's rich menu panels.
struct UsageMenuCardView: View {
    struct Model {
        enum PercentStyle: String, Sendable {
            case left
            case used

            var labelSuffix: String {
                switch self {
                case .left: "left"
                case .used: "used"
                }
            }

            var accessibilityLabel: String {
                switch self {
                case .left: "Usage remaining"
                case .used: "Usage used"
                }
            }
        }

        struct Metric: Identifiable {
            let id: String
            let title: String
            let percent: Double
            let percentStyle: PercentStyle
            let resetText: String?
            let detailText: String?

            var percentLabel: String {
                String(format: "%.0f%% %@", self.percent, self.percentStyle.labelSuffix)
            }
        }

        enum SubtitleStyle {
            case info
            case loading
            case error
        }

        struct TokenUsageSection: Sendable {
            let sessionLine: String
            let monthLine: String
            let hintLine: String?
            let errorLine: String?
            let errorCopyText: String?
        }

        struct ProviderCostSection: Sendable {
            let title: String
            let percentUsed: Double
            let spendLine: String
        }

        let providerName: String
        let email: String
        let subtitleText: String
        let subtitleStyle: SubtitleStyle
        let planText: String?
        let metrics: [Metric]
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

    init(model: Model, width: CGFloat) {
        self.model = model
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageMenuCardHeaderView(model: self.model)

            if self.hasDetails {
                Divider()
            }

            if self.model.metrics.isEmpty {
                if let placeholder = self.model.placeholder {
                    Text(placeholder)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .font(.subheadline)
                }
            } else {
                let hasUsage = !self.model.metrics.isEmpty
                let hasCredits = self.model.creditsText != nil
                let hasProviderCost = self.model.providerCost != nil
                let hasCost = self.model.tokenUsage != nil || hasProviderCost

                VStack(alignment: .leading, spacing: 12) {
                    if hasUsage {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(self.model.metrics) { metric in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(metric.title)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    UsageProgressBar(
                                        percent: metric.percent,
                                        tint: self.model.progressColor,
                                        accessibilityLabel: metric.percentStyle.accessibilityLabel)
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(metric.percentLabel)
                                            .font(.footnote)
                                        Spacer()
                                        if let reset = metric.resetText {
                                            Text(reset)
                                                .font(.footnote)
                                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                        }
                                    }
                                    if let detail = metric.detailText {
                                        Text(detail)
                                            .font(.footnote)
                                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                            .lineLimit(1)
                                    }
                                }
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
                            Text("Cost")
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
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .frame(width: self.width, alignment: .leading)
    }

    private var hasDetails: Bool {
        !self.model.metrics.isEmpty || self.model.placeholder != nil || self.model.tokenUsage != nil ||
            self.model.providerCost != nil
    }
}

private struct UsageMenuCardHeaderView: View {
    let model: UsageMenuCardView.Model
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.model.providerName)
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text(self.model.email)
                    .font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            }
            if self.model.subtitleStyle == .error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.model.subtitleText)
                        .font(.footnote)
                        .foregroundStyle(self.subtitleColor)
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .firstTextBaseline) {
                        if !self.model.subtitleText.isEmpty {
                            CopyIconButton(copyText: self.model.subtitleText, isHighlighted: self.isHighlighted)
                        }
                        Spacer()
                        if let plan = self.model.planText {
                            Text(plan)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.model.subtitleText)
                        .font(.footnote)
                        .foregroundStyle(self.subtitleColor)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer()
                    if let plan = self.model.planText {
                        Text(plan)
                            .font(.footnote)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }
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
        .accessibilityLabel(self.didCopy ? "Copied" : "Copy error")
    }

    private func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(self.copyText, forType: .string)
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
            UsageProgressBar(
                percent: self.section.percentUsed,
                tint: self.progressColor,
                accessibilityLabel: "Extra usage spent")
            HStack(alignment: .firstTextBaseline) {
                Text(self.section.spendLine)
                    .font(.footnote)
                Spacer()
                Text(String(format: "%.0f%% used", min(100, max(0, self.section.percentUsed))))
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            }
        }
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
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, self.model.subtitleStyle == .error ? 2 : 0)
        .frame(width: self.width, alignment: .leading)
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
                if let placeholder = self.model.placeholder {
                    Text(placeholder)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .font(.subheadline)
                }
            } else {
                ForEach(self.model.metrics) { metric in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(metric.title)
                            .font(.body)
                            .fontWeight(.medium)
                        UsageProgressBar(
                            percent: metric.percent,
                            tint: self.model.progressColor,
                            accessibilityLabel: metric.percentStyle.accessibilityLabel)
                        HStack(alignment: .firstTextBaseline) {
                            Text(metric.percentLabel)
                                .font(.footnote)
                            Spacer()
                            if let reset = metric.resetText {
                                Text(reset)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            }
                        }
                        if let detail = metric.detailText {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                .lineLimit(1)
                        }
                    }
                }
            }
            if self.showBottomDivider {
                Divider()
            }
        }
        .padding(.horizontal, 16)
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

    init(
        model: UsageMenuCardView.Model,
        showBottomDivider: Bool,
        topPadding: CGFloat,
        bottomPadding: CGFloat,
        width: CGFloat)
    {
        self.model = model
        self.showBottomDivider = showBottomDivider
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.width = width
    }

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
            .padding(.horizontal, 16)
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
        return "\(scale) tokens"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Credits")
                .font(.body)
                .fontWeight(.medium)
            if let percentLeft {
                UsageProgressBar(
                    percent: percentLeft,
                    tint: self.progressColor,
                    accessibilityLabel: "Credits remaining")
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
                            Text("Cost")
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
                .padding(.horizontal, 16)
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
                    .padding(.horizontal, 16)
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
        let hidePersonalInfo: Bool
        let now: Date
    }

    static func make(_ input: Input) -> UsageMenuCardView.Model {
        let email = Self.email(
            for: input.provider,
            snapshot: input.snapshot,
            account: input.account,
            metadata: input.metadata,
            hidePersonalInfo: input.hidePersonalInfo)
        let planText = Self.plan(
            for: input.provider,
            snapshot: input.snapshot,
            account: input.account,
            metadata: input.metadata)
        let metrics = Self.metrics(input: input)
        let creditsText: String? = if input.provider == .codex, !input.showOptionalCreditsAndExtraUsage {
            nil
        } else {
            Self.creditsLine(metadata: input.metadata, credits: input.credits, error: input.creditsError)
        }
        let creditsHintText = Self.dashboardHint(
            provider: input.provider,
            error: input.dashboardError,
            hidePersonalInfo: input.hidePersonalInfo)
        let providerCost: ProviderCostSection? = if input.provider == .claude, !input.showOptionalCreditsAndExtraUsage {
            nil
        } else {
            Self.providerCostSection(provider: input.provider, cost: input.snapshot?.providerCost)
        }
        let tokenUsage = Self.tokenUsageSection(
            provider: input.provider,
            enabled: input.tokenCostUsageEnabled,
            snapshot: input.tokenSnapshot,
            error: input.tokenError,
            hidePersonalInfo: input.hidePersonalInfo)
        let subtitle = Self.subtitle(
            snapshot: input.snapshot,
            isRefreshing: input.isRefreshing,
            lastError: input.lastError,
            hidePersonalInfo: input.hidePersonalInfo)
        let placeholder = input.snapshot == nil && !input.isRefreshing && input.lastError == nil ? "No usage yet" : nil

        return UsageMenuCardView.Model(
            providerName: input.metadata.displayName,
            email: email,
            subtitleText: subtitle.text,
            subtitleStyle: subtitle.style,
            planText: planText,
            metrics: metrics,
            creditsText: creditsText,
            creditsRemaining: input.credits?.remaining,
            creditsHintText: creditsHintText,
            creditsHintCopyText: (input.dashboardError?.isEmpty ?? true) ? nil : input.dashboardError,
            providerCost: providerCost,
            tokenUsage: tokenUsage,
            placeholder: placeholder,
            progressColor: Self.progressColor(for: input.provider))
    }

    private static func email(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo,
        metadata: ProviderMetadata,
        hidePersonalInfo: Bool) -> String
    {
        if let email = snapshot?.accountEmail(for: provider), !email.isEmpty {
            return PersonalInfoRedactor.redactEmail(email, isEnabled: hidePersonalInfo)
        }
        if metadata.usesAccountFallback,
           let email = account.email, !email.isEmpty
        {
            return PersonalInfoRedactor.redactEmail(email, isEnabled: hidePersonalInfo)
        }
        return ""
    }

    private static func plan(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo,
        metadata: ProviderMetadata) -> String?
    {
        if let plan = snapshot?.loginMethod(for: provider), !plan.isEmpty {
            return self.planDisplay(plan)
        }
        if metadata.usesAccountFallback,
           let plan = account.plan, !plan.isEmpty
        {
            return Self.planDisplay(plan)
        }
        return nil
    }

    private static func planDisplay(_ text: String) -> String {
        let cleaned = UsageFormatter.cleanPlanName(text)
        return cleaned.isEmpty ? text : cleaned
    }

    private static func subtitle(
        snapshot: UsageSnapshot?,
        isRefreshing: Bool,
        lastError: String?,
        hidePersonalInfo: Bool) -> (text: String, style: SubtitleStyle)
    {
        if let lastError, !lastError.isEmpty {
            let trimmed = lastError.trimmingCharacters(in: .whitespacesAndNewlines)
            let redacted = PersonalInfoRedactor.redactEmails(in: trimmed, isEnabled: hidePersonalInfo) ?? trimmed
            return (redacted, .error)
        }

        if isRefreshing, snapshot == nil {
            return ("Refreshing...", .loading)
        }

        if let updated = snapshot?.updatedAt {
            return (UsageFormatter.updatedString(from: updated), .info)
        }

        return ("Not fetched yet", .info)
    }

    private static func metrics(input: Input) -> [Metric] {
        guard let snapshot = input.snapshot else { return [] }
        var metrics: [Metric] = []
        let percentStyle: PercentStyle = input.usageBarsShowUsed ? .used : .left
        let zaiUsage = input.provider == .zai ? snapshot.zaiUsage : nil
        let zaiTokenDetail = Self.zaiLimitDetailText(limit: zaiUsage?.tokenLimit)
        let zaiTimeDetail = Self.zaiLimitDetailText(limit: zaiUsage?.timeLimit)
        if let primary = snapshot.primary {
            metrics.append(Metric(
                id: "primary",
                title: input.metadata.sessionLabel,
                percent: Self.clamped(
                    input.usageBarsShowUsed ? primary.usedPercent : primary.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: primary, style: input.resetTimeDisplayStyle, now: input.now),
                detailText: input.provider == .zai ? zaiTokenDetail : nil))
        }
        if let weekly = snapshot.secondary {
            let paceText = UsagePaceText.weekly(provider: input.provider, window: weekly, now: input.now)
            metrics.append(Metric(
                id: "secondary",
                title: input.metadata.weeklyLabel,
                percent: Self.clamped(input.usageBarsShowUsed ? weekly.usedPercent : weekly.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: weekly, style: input.resetTimeDisplayStyle, now: input.now),
                detailText: input.provider == .zai ? zaiTimeDetail : paceText))
        }
        if input.metadata.supportsOpus, let opus = snapshot.tertiary {
            metrics.append(Metric(
                id: "tertiary",
                title: input.metadata.opusLabel ?? "Sonnet",
                percent: Self.clamped(input.usageBarsShowUsed ? opus.usedPercent : opus.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: opus, style: input.resetTimeDisplayStyle, now: input.now),
                detailText: nil))
        }

        if input.provider == .codex, let remaining = input.dashboard?.codeReviewRemainingPercent {
            let percent = input.usageBarsShowUsed ? (100 - remaining) : remaining
            metrics.append(Metric(
                id: "code-review",
                title: "Code review",
                percent: Self.clamped(percent),
                percentStyle: percentStyle,
                resetText: nil,
                detailText: nil))
        }
        return metrics
    }

    private static func zaiLimitDetailText(limit: ZaiLimitEntry?) -> String? {
        guard let limit else { return nil }
        let currentStr = UsageFormatter.tokenCountString(limit.currentValue)
        let usageStr = UsageFormatter.tokenCountString(limit.usage)
        let remainingStr = UsageFormatter.tokenCountString(limit.remaining)
        return "\(currentStr) / \(usageStr) (\(remainingStr) remaining)"
    }

    private static func creditsLine(
        metadata: ProviderMetadata,
        credits: CreditsSnapshot?,
        error: String?) -> String?
    {
        guard metadata.supportsCredits else { return nil }
        if let credits {
            return UsageFormatter.creditsString(from: credits.remaining)
        }
        if let error, !error.isEmpty {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return metadata.creditsHint
    }

    private static func dashboardHint(
        provider: UsageProvider,
        error: String?,
        hidePersonalInfo: Bool) -> String?
    {
        guard provider == .codex else { return nil }
        guard let error, !error.isEmpty else { return nil }
        return PersonalInfoRedactor.redactEmails(in: error, isEnabled: hidePersonalInfo) ?? error
    }

    private static func tokenUsageSection(
        provider: UsageProvider,
        enabled: Bool,
        snapshot: CostUsageTokenSnapshot?,
        error: String?,
        hidePersonalInfo: Bool) -> TokenUsageSection?
    {
        guard provider == .codex || provider == .claude || provider == .vertexai else { return nil }
        guard enabled else { return nil }
        guard let snapshot else { return nil }

        let sessionCost = snapshot.sessionCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let sessionTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let sessionLine: String = {
            if let sessionTokens {
                return "Today: \(sessionCost) · \(sessionTokens) tokens"
            }
            return "Today: \(sessionCost)"
        }()

        let monthCost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let monthTokens = monthTokensValue.map { UsageFormatter.tokenCountString($0) }
        let monthLine: String = {
            if let monthTokens {
                return "Last 30 days: \(monthCost) · \(monthTokens) tokens"
            }
            return "Last 30 days: \(monthCost)"
        }()
        let err = (error?.isEmpty ?? true) ? nil : error
        let redacted = PersonalInfoRedactor.redactEmails(in: err, isEnabled: hidePersonalInfo)
        return TokenUsageSection(
            sessionLine: sessionLine,
            monthLine: monthLine,
            hintLine: nil,
            errorLine: redacted ?? err,
            errorCopyText: (error?.isEmpty ?? true) ? nil : (redacted ?? error))
    }

    private static func providerCostSection(
        provider: UsageProvider,
        cost: ProviderCostSnapshot?) -> ProviderCostSection?
    {
        guard let cost else { return nil }
        guard cost.limit > 0 else { return nil }

        let used: String
        let limit: String
        let title: String

        if cost.currencyCode == "Quota" {
            title = "Quota usage"
            used = String(format: "%.0f", cost.used)
            limit = String(format: "%.0f", cost.limit)
        } else {
            title = "Extra usage"
            used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
        }

        let percentUsed = Self.clamped((cost.used / cost.limit) * 100)
        let periodLabel = cost.period ?? "This month"

        return ProviderCostSection(
            title: title,
            percentUsed: percentUsed,
            spendLine: "\(periodLabel): \(used) / \(limit)")
    }

    private static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func progressColor(for provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private static func resetText(
        for window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date) -> String?
    {
        UsageFormatter.resetLine(for: window, style: style, now: now)
    }
}

// MARK: - Copy-on-click overlay

private struct ClickToCopyOverlay: NSViewRepresentable {
    let copyText: String

    func makeNSView(context: Context) -> ClickToCopyView {
        ClickToCopyView(copyText: self.copyText)
    }

    func updateNSView(_ nsView: ClickToCopyView, context: Context) {
        nsView.copyText = self.copyText
    }
}

private final class ClickToCopyView: NSView {
    var copyText: String

    init(copyText: String) {
        self.copyText = copyText
        super.init(frame: .zero)
        self.wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        _ = event
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(self.copyText, forType: .string)
    }
}
