import CodexBarCore
import SwiftUI

struct CodexResetCreditPresentationItem: Equatable {
    let expiryText: String
    let compactExpiryText: String
}

struct CodexResetCreditsPresentation: Equatable {
    let text: String
    let items: [CodexResetCreditPresentationItem]

    var expirySummaryText: String {
        let visibleItems = self.items.prefix(4).map(\.compactExpiryText)
        let hiddenCount = self.items.count - visibleItems.count
        let suffix = hiddenCount > 0 ? ["+\(hiddenCount)"] : []
        return (visibleItems + suffix).joined(separator: " · ")
    }

    var helpText: String {
        self.items.enumerated().map { index, item in
            "\(index + 1). \(item.expiryText)"
        }.joined(separator: "\n")
    }

    var accessibilityLabel: String {
        [L("Limit Reset Credits"), self.text, self.helpText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func make(
        snapshot: CodexRateLimitResetCreditsSnapshot,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> CodexResetCreditsPresentation?
    {
        let inventory = snapshot.availableInventory(at: now)
        guard !inventory.credits.isEmpty else { return nil }
        let items = inventory.credits.map { credit in
            Self.presentationItem(for: credit, resetStyle: resetStyle, now: now)
        }
        return CodexResetCreditsPresentation(
            text: Self.availableText(count: inventory.count),
            items: items)
    }

    private static func availableText(count: Int) -> String {
        count == 1 ? L("1 available") : String(format: L("%d available"), count)
    }

    private static func presentationItem(
        for credit: CodexRateLimitResetCredit,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> CodexResetCreditPresentationItem
    {
        guard let expiresAt = credit.expiresAt else {
            return CodexResetCreditPresentationItem(expiryText: L("No expiry"), compactExpiryText: L("No expiry"))
        }
        let formattedTime = Self.formattedTime(expiresAt, resetStyle: resetStyle, now: now)
        let compactExpiryText = resetStyle == .countdown && formattedTime.hasPrefix("in ")
            ? String(formattedTime.dropFirst(3))
            : formattedTime
        return CodexResetCreditPresentationItem(
            expiryText: String(format: L("Expires %@"), formattedTime),
            compactExpiryText: compactExpiryText)
    }

    private static func formattedTime(
        _ expiresAt: Date,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> String
    {
        switch resetStyle {
        case .absolute:
            return UsageFormatter.resetDescription(from: expiresAt, now: now)
        case .countdown:
            let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: now)
            return countdown == "now" ? L("now") : countdown
        }
    }
}

struct CodexResetCreditsContent: View {
    let presentation: CodexResetCreditsPresentation
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Limit Reset Credits"))
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.presentation.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(self.presentation.expirySummaryText)
                        .font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(self.presentation.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.presentation.accessibilityLabel)
    }
}

extension UsageMenuCardView.Model {
    static func codexResetCredits(input: Input) -> CodexResetCreditsPresentation? {
        guard input.provider == .codex,
              let resetCredits = input.snapshot?.codexResetCredits
        else {
            return nil
        }
        return CodexResetCreditsPresentation.make(
            snapshot: resetCredits,
            resetStyle: input.resetTimeDisplayStyle,
            now: input.now)
    }
}
