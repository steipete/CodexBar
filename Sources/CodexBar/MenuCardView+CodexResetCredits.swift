import CodexBarCore
import SwiftUI

struct CodexResetCreditsContent: View {
    let text: String
    let detailText: String?
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Limit Reset Credits"))
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(self.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if let detailText, !detailText.isEmpty {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
            L("Limit Reset Credits"),
            self.text,
            self.detailText,
        ].compactMap(\.self).joined(separator: ", "))
    }
}

extension UsageMenuCardView.Model {
    static func codexResetCreditsText(input: Input) -> String? {
        guard input.provider == .codex,
              input.showOptionalCreditsAndExtraUsage,
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

    static func codexResetCreditsDetailText(input: Input) -> String? {
        guard input.provider == .codex,
              input.showOptionalCreditsAndExtraUsage,
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
}
