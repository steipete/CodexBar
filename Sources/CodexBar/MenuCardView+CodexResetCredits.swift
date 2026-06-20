import CodexBarCore
import SwiftUI

struct CodexResetCreditsPresentation: Equatable {
    let text: String
    let detailText: String?
    let helpText: String?
    let creditToConsume: CodexRateLimitResetCredit?
}

struct CodexResetCreditsContent: View {
    let model: CodexResetCreditsPresentation

    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.codexResetCreditConsumer) private var consumeCredit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Limit Reset Credits"))
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.model.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if let detailText = self.model.detailText, !detailText.isEmpty {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
                if let creditToConsume = self.model.creditToConsume, let consumeCredit {
                    Button(L("Use Reset")) {
                        consumeCredit(creditToConsume)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L("Use the next expiring Codex reset credit"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(self.model.helpText ?? self.model.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
            L("Limit Reset Credits"),
            self.model.text,
            self.model.detailText,
        ].compactMap(\.self).joined(separator: ", "))
    }
}

extension UsageMenuCardView.Model {
    static func codexResetCredits(input: Input) -> CodexResetCreditsPresentation? {
        guard input.showOptionalCreditsAndExtraUsage else { return nil }
        guard let text = codexResetCreditsText(input: input) else { return nil }
        return CodexResetCreditsPresentation(
            text: text,
            detailText: Self.codexResetCreditsDetailText(input: input),
            helpText: Self.codexResetCreditsHelpText(input: input),
            creditToConsume: Self.codexResetCreditToConsume(input: input))
    }

    static func codexResetCreditsText(input: Input) -> String? {
        guard input.provider == .codex,
              let resetCredits = input.snapshot?.codexResetCredits,
              resetCredits.availableCount > 0
        else {
            return nil
        }
        let count = resetCredits.availableCount
        if count == 1 {
            return L("1 available")
        }
        return String(format: L("%d available"), count)
    }

    static func codexResetCreditToConsume(input: Input) -> CodexRateLimitResetCredit? {
        guard input.provider == .codex
        else {
            return nil
        }
        return input.snapshot?.codexResetCredits?.nextExpiringAvailableCredit
    }

    static func codexResetCreditsDetailText(input: Input) -> String? {
        guard input.provider == .codex,
              let resetCredits = input.snapshot?.codexResetCredits,
              let expiresAt = resetCredits.nextExpiringAvailableCredit?.expiresAt
        else {
            return nil
        }
        let timeText: String
        switch input.resetTimeDisplayStyle {
        case .absolute:
            timeText = UsageFormatter.resetDescription(from: expiresAt, now: input.now)
        case .countdown:
            let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: input.now)
            timeText = countdown == "now" ? L("now") : countdown
        }
        return String(format: L("Next expires %@"), timeText)
    }

    static func codexResetCreditsHelpText(input: Input) -> String? {
        guard input.provider == .codex,
              let resetCredits = input.snapshot?.codexResetCredits
        else {
            return nil
        }
        let lines = resetCredits.credits.map { credit in
            let expires = Self.codexResetCreditExpiryText(credit, now: input.now)
            return "\(credit.status.rawValue), \(expires)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func codexResetCreditExpiryText(
        _ credit: CodexRateLimitResetCredit,
        now: Date)
        -> String
    {
        guard let expiresAt = credit.expiresAt else { return L("No expiry") }
        let absolute = UsageFormatter.resetDescription(from: expiresAt, now: now)
        guard credit.status == .available, expiresAt > now else { return absolute }
        let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: now)
        return "\(countdown) (\(absolute))"
    }
}
