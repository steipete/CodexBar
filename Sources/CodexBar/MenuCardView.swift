import CodexBarCore
import SwiftUI

/// SwiftUI card used inside the NSMenu to mirror Apple's rich menu panels.
struct UsageMenuCardView: View {
    struct Model {
        struct Metric: Identifiable {
            let id: String
            let title: String
            let percentLeft: Double
            let resetText: String?

            var percentLabel: String {
                String(format: "%.0f%% left", self.percentLeft)
            }
        }

        enum SubtitleStyle {
            case info
            case loading
            case error
        }

        let providerName: String
        let email: String
        let subtitleText: String
        let subtitleStyle: SubtitleStyle
        let planText: String?
        let metrics: [Metric]
        let creditsText: String?
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

            Divider()

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
                            UsageProgressBar(percentLeft: metric.percentLeft, tint: self.model.progressColor)
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
                        }
                    }
                    if let credits = self.model.creditsText {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Credits")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(credits)
                                .font(.footnote)
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
        let account: AccountInfo
        let isRefreshing: Bool
        let lastError: String?
    }

    static func make(_ input: Input) -> UsageMenuCardView.Model {
        let email = Self.email(
            for: input.provider,
            snapshot: input.snapshot,
            account: input.account)
        let planText = Self.plan(for: input.provider, snapshot: input.snapshot, account: input.account)
        let metrics = Self.metrics(metadata: input.metadata, snapshot: input.snapshot)
        let creditsText = Self.creditsLine(metadata: input.metadata, credits: input.credits, error: input.creditsError)
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
        case .claude:
            if let email = snapshot?.accountEmail, !email.isEmpty { return email }
        }
        return ""
    }

    private static func plan(for provider: UsageProvider, snapshot: UsageSnapshot?, account: AccountInfo) -> String? {
        switch provider {
        case .codex:
            if let plan = snapshot?.loginMethod, !plan.isEmpty { return self.planDisplay(plan) }
            if let plan = account.plan, !plan.isEmpty { return Self.planDisplay(plan) }
        case .claude:
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

    private static func metrics(metadata: ProviderMetadata, snapshot: UsageSnapshot?) -> [Metric] {
        guard let snapshot else { return [] }
        var metrics: [Metric] = []
        metrics.append(Metric(
            id: "primary",
            title: metadata.sessionLabel,
            percentLeft: Self.clamped(snapshot.primary.remainingPercent),
            resetText: Self.resetText(for: snapshot.primary)))
        metrics.append(Metric(
            id: "secondary",
            title: metadata.weeklyLabel,
            percentLeft: Self.clamped(snapshot.secondary.remainingPercent),
            resetText: Self.resetText(for: snapshot.secondary)))
        if metadata.supportsOpus, let opus = snapshot.tertiary {
            metrics.append(Metric(
                id: "tertiary",
                title: metadata.opusLabel ?? "Sonnet",
                percentLeft: Self.clamped(opus.remainingPercent),
                resetText: Self.resetText(for: opus)))
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

    private static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func progressColor(for provider: UsageProvider) -> Color {
        switch provider {
        case .codex:
            Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .claude:
            Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        }
    }

    private static func resetText(for window: RateWindow) -> String? {
        if let date = window.resetsAt {
            return "Resets \(UsageFormatter.resetDescription(from: date))"
        }

        if let desc = window.resetDescription, !desc.isEmpty {
            return desc
        }
        return nil
    }
}
