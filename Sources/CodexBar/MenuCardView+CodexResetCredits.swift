import CodexBarCore
import SwiftUI

struct CodexResetCreditPresentationItem: Equatable {
    let expiryText: String
}

struct CodexResetCreditsPresentation: Equatable {
    let text: String
    let detailText: String?
    let items: [CodexResetCreditPresentationItem]

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
            CodexResetCreditPresentationItem(
                expiryText: Self.expiryText(for: credit, resetStyle: resetStyle, now: now))
        }
        let detailText = inventory.nextExpiringCredit.flatMap { credit in
            credit.expiresAt.map { expiresAt in
                String(
                    format: L("Next expires %@"),
                    Self.formattedTime(expiresAt, resetStyle: resetStyle, now: now))
            }
        } ?? (inventory.credits.allSatisfy { $0.expiresAt == nil } ? L("No expiry") : nil)
        return CodexResetCreditsPresentation(
            text: Self.availableText(count: inventory.count),
            detailText: detailText,
            items: items)
    }

    private static func availableText(count: Int) -> String {
        count == 1 ? L("1 available") : String(format: L("%d available"), count)
    }

    private static func expiryText(
        for credit: CodexRateLimitResetCredit,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> String
    {
        guard let expiresAt = credit.expiresAt else { return L("No expiry") }
        return String(
            format: L("Expires %@"),
            Self.formattedTime(expiresAt, resetStyle: resetStyle, now: now))
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

    nonisolated static func expiryRows(_ presentation: CodexResetCreditsPresentation) -> [String] {
        presentation.items.map(\.expiryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Limit Reset Credits"))
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(self.presentation.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if let detailText = self.presentation.detailText, !detailText.isEmpty {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
            ForEach(Array(Self.expiryRows(self.presentation).enumerated()), id: \.offset) { index, expiryText in
                Text("\(index + 1). \(expiryText)")
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
