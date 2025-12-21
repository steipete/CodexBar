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
        }

        let providerName: String
        let email: String
        let subtitleText: String
        let subtitleStyle: SubtitleStyle
        let planText: String?
        let metrics: [Metric]
        let creditsText: String?
        let creditsHintText: String?
        let tokenUsage: TokenUsageSection?
        let placeholder: String?
        let progressColor: Color
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.model.providerName)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(self.model.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Text(self.model.subtitleText)
                        .font(.footnote)
                        .foregroundStyle(self.subtitleColor)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let plan = self.model.planText {
                        Text(plan)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if self.hasDetails {
                Divider()
            }

            if self.model.metrics.isEmpty {
                if let placeholder = self.model.placeholder {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(self.model.metrics) { metric in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(metric.title)
                                .font(.subheadline)
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
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let detail = metric.detailText {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if let credits = self.model.creditsText {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Credits")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(credits)
                                .font(.footnote)
                            if let hint = self.model.creditsHintText, !hint.isEmpty {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if self.model.creditsText != nil, self.model.tokenUsage != nil {
                        Divider()
                    }
                    if let tokenUsage = self.model.tokenUsage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cost")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(tokenUsage.sessionLine)
                                .font(.footnote)
                            Text(tokenUsage.monthLine)
                                .font(.footnote)
                            if let hint = tokenUsage.hintLine, !hint.isEmpty {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = tokenUsage.errorLine, !error.isEmpty {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(Color(nsColor: .systemRed))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.bottom, self.model.creditsText == nil ? 8 : 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(minWidth: 300, maxWidth: 300, alignment: .leading)
    }

    private var hasDetails: Bool {
        !self.model.metrics.isEmpty || self.model.placeholder != nil || self.model.tokenUsage != nil
    }

    private var subtitleColor: Color {
        switch self.model.subtitleStyle {
        case .info: .secondary
        case .loading: .secondary
        case .error: Color(nsColor: .systemRed)
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
        let tokenSnapshot: CCUsageTokenSnapshot?
        let tokenError: String?
        let account: AccountInfo
        let isRefreshing: Bool
        let lastError: String?
        let usageBarsShowUsed: Bool
        let tokenCostUsageEnabled: Bool
        let now: Date
    }

    static func make(_ input: Input) -> UsageMenuCardView.Model {
        let email = Self.email(
            for: input.provider,
            snapshot: input.snapshot,
            account: input.account)
        let planText = Self.plan(for: input.provider, snapshot: input.snapshot, account: input.account)
        let metrics = Self.metrics(input: input)
        let creditsText = Self.creditsLine(metadata: input.metadata, credits: input.credits, error: input.creditsError)
        let creditsHintText = Self.dashboardHint(provider: input.provider, error: input.dashboardError)
        let tokenUsage = Self.tokenUsageSection(
            provider: input.provider,
            enabled: input.tokenCostUsageEnabled,
            snapshot: input.tokenSnapshot,
            error: input.tokenError)
        let subtitle = Self.subtitle(
            snapshot: input.snapshot,
            isRefreshing: input.isRefreshing,
            lastError: input.lastError)
        let placeholder = input.snapshot == nil && !input.isRefreshing && input.lastError == nil ? "No usage yet" : nil

        return UsageMenuCardView.Model(
            providerName: input.metadata.displayName,
            email: email,
            subtitleText: subtitle.text,
            subtitleStyle: subtitle.style,
            planText: planText,
            metrics: metrics,
            creditsText: creditsText,
            creditsHintText: creditsHintText,
            tokenUsage: tokenUsage,
            placeholder: placeholder,
            progressColor: Self.progressColor(for: input.provider))
    }

    private static func email(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo) -> String
    {
        switch provider {
        case .codex:
            if let email = snapshot?.accountEmail, !email.isEmpty { return email }
            if let email = account.email, !email.isEmpty { return email }
        case .claude, .gemini:
            if let email = snapshot?.accountEmail, !email.isEmpty { return email }
        }
        return ""
    }

    private static func plan(for provider: UsageProvider, snapshot: UsageSnapshot?, account: AccountInfo) -> String? {
        switch provider {
        case .codex:
            if let plan = snapshot?.loginMethod, !plan.isEmpty { return self.planDisplay(plan) }
            if let plan = account.plan, !plan.isEmpty { return Self.planDisplay(plan) }
        case .claude, .gemini:
            if let plan = snapshot?.loginMethod, !plan.isEmpty { return self.planDisplay(plan) }
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
        lastError: String?) -> (text: String, style: SubtitleStyle)
    {
        if let lastError, !lastError.isEmpty {
            return (UsageFormatter.truncatedSingleLine(lastError, max: 80), .error)
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
        metrics.append(Metric(
            id: "primary",
            title: input.metadata.sessionLabel,
            percent: Self.clamped(
                input.usageBarsShowUsed ? snapshot.primary.usedPercent : snapshot.primary.remainingPercent),
            percentStyle: percentStyle,
            resetText: Self.resetText(for: snapshot.primary, prefersCountdown: true),
            detailText: nil))
        if let weekly = snapshot.secondary {
            let paceText = UsagePaceText.weekly(provider: input.provider, window: weekly, now: input.now)
            metrics.append(Metric(
                id: "secondary",
                title: input.metadata.weeklyLabel,
                percent: Self.clamped(input.usageBarsShowUsed ? weekly.usedPercent : weekly.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: weekly, prefersCountdown: true),
                detailText: paceText))
        }
        if input.metadata.supportsOpus, let opus = snapshot.tertiary {
            metrics.append(Metric(
                id: "tertiary",
                title: input.metadata.opusLabel ?? "Sonnet",
                percent: Self.clamped(input.usageBarsShowUsed ? opus.usedPercent : opus.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: opus, prefersCountdown: true),
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
            return UsageFormatter.truncatedSingleLine(error, max: 80)
        }
        return metadata.creditsHint
    }

    private static func dashboardHint(provider: UsageProvider, error: String?) -> String? {
        guard provider == .codex else { return nil }
        guard let error, !error.isEmpty else { return nil }
        return UsageFormatter.truncatedSingleLine(error, max: 100)
    }

    private static func tokenUsageSection(
        provider: UsageProvider,
        enabled: Bool,
        snapshot: CCUsageTokenSnapshot?,
        error: String?) -> TokenUsageSection?
    {
        guard provider == .codex || provider == .claude else { return nil }
        guard enabled else { return nil }
        guard let snapshot else { return nil }

        let sessionCost = snapshot.sessionCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let sessionTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let sessionLine: String = {
            if let sessionTokens {
                return "Session: \(sessionCost) · \(sessionTokens) tokens"
            }
            return "Session: \(sessionCost)"
        }()

        let monthCost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let err = (error?.isEmpty ?? true) ? nil : UsageFormatter.truncatedSingleLine(error!, max: 120)
        return TokenUsageSection(
            sessionLine: sessionLine,
            monthLine: "Last 30 days: \(monthCost)",
            hintLine: nil,
            errorLine: err)
    }

    private static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func progressColor(for provider: UsageProvider) -> Color {
        switch provider {
        case .codex:
            Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .claude:
            Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        case .gemini:
            Color(red: 171 / 255, green: 135 / 255, blue: 234 / 255) // #AB87EA
        }
    }

    private static func resetText(for window: RateWindow, prefersCountdown: Bool) -> String? {
        if let date = window.resetsAt {
            if prefersCountdown {
                return "Resets \(UsageFormatter.resetCountdownDescription(from: date))"
            }
            return "Resets \(UsageFormatter.resetDescription(from: date))"
        }

        if let desc = window.resetDescription, !desc.isEmpty {
            return desc
        }
        return nil
    }
}
