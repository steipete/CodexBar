import CodexBarCore
import SwiftUI

struct LimitResetCreditPresentationItem: Equatable {
    let expiryText: String
    let compactExpiryText: String
}

struct LimitResetCreditsPresentation: Equatable {
    let title: String
    let text: String
    let items: [LimitResetCreditPresentationItem]

    init(
        title: String = L("Limit Reset Credits"),
        text: String,
        items: [LimitResetCreditPresentationItem])
    {
        self.title = title
        self.text = text
        self.items = items
    }

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
        [self.title, self.text, self.helpText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func make(
        snapshot: CodexRateLimitResetCreditsSnapshot,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> LimitResetCreditsPresentation?
    {
        let inventory = snapshot.availableInventory(at: now)
        guard !inventory.credits.isEmpty else { return nil }
        return Self.make(
            expirations: inventory.credits.map(\.expiresAt),
            resetStyle: resetStyle,
            now: now)
    }

    static func make(
        snapshot: GrokRateLimitResetCreditsSnapshot,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> LimitResetCreditsPresentation?
    {
        self.make(
            expirations: snapshot.availableExpirations(at: now).map(Optional.some),
            resetStyle: resetStyle,
            now: now)
    }

    static func make(
        details: [ProviderDetailSection]) -> LimitResetCreditsPresentation?
    {
        guard let row = details.lazy.flatMap(\.rows).first(where: { $0.label == "Limit Reset Credits" }) else {
            return nil
        }
        let text = Self.localizedAvailableText(row.value)
        let items = row.secondaryValue.map { secondaryValue -> [LimitResetCreditPresentationItem] in
            let prefix = "Expires "
            let compact = secondaryValue.hasPrefix(prefix)
                ? String(secondaryValue.dropFirst(prefix.count))
                : secondaryValue
            return [.init(
                expiryText: secondaryValue.hasPrefix(prefix) ? L("Expires %@", compact) : secondaryValue,
                compactExpiryText: compact)]
        } ?? []
        return LimitResetCreditsPresentation(text: text, items: items)
    }

    private static func availableText(count: Int) -> String {
        count == 1 ? L("1 available") : String(format: L("%d available"), count)
    }

    private static func make(
        expirations: [Date?],
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> LimitResetCreditsPresentation?
    {
        guard !expirations.isEmpty else { return nil }
        return LimitResetCreditsPresentation(
            text: self.availableText(count: expirations.count),
            items: expirations.map { expiration in
                Self.presentationItem(expiresAt: expiration, resetStyle: resetStyle, now: now)
            })
    }

    private static func localizedAvailableText(_ value: String) -> String {
        if value == "1 available" { return L("1 available") }
        let suffix = " available"
        guard value.hasSuffix(suffix), let count = Int(value.dropLast(suffix.count)) else { return value }
        return L("%d available", count)
    }

    private static func presentationItem(
        expiresAt: Date?,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> LimitResetCreditPresentationItem
    {
        guard let expiresAt else {
            return LimitResetCreditPresentationItem(expiryText: L("No expiry"), compactExpiryText: L("No expiry"))
        }
        let formattedTime = Self.formattedTime(expiresAt, resetStyle: resetStyle, now: now)
        let compactExpiryText = resetStyle == .countdown && formattedTime.hasPrefix("in ")
            ? String(formattedTime.dropFirst(3))
            : formattedTime
        return LimitResetCreditPresentationItem(
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

struct LimitResetCreditsContent: View {
    let presentation: LimitResetCreditsPresentation
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.presentation.title)
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
    static func limitResetCredits(input: Input) -> LimitResetCreditsPresentation? {
        switch input.provider {
        case .codex:
            guard let resetCredits = input.snapshot?.codexResetCredits else { return nil }
            return LimitResetCreditsPresentation.make(
                snapshot: resetCredits,
                resetStyle: input.resetTimeDisplayStyle,
                now: input.now)
        case .grok:
            guard input.showOptionalCreditsAndExtraUsage else { return nil }
            if let resetCredits = input.snapshot?.grokResetCredits {
                return LimitResetCreditsPresentation.make(
                    snapshot: resetCredits,
                    resetStyle: input.resetTimeDisplayStyle,
                    now: input.now)
            }
            return LimitResetCreditsPresentation.make(details: input.snapshot?.details ?? [])
        default:
            return nil
        }
    }
}
