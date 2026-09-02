import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func localizedProviderDetails(
        _ details: [ProviderDetailSection],
        provider: UsageProvider) -> [ProviderDetailSection]
    {
        // Provider-specific by design: DeepSeek, z.ai, Kiro, and Grok rewrite value phrasing.
        // Other providers localize section titles and row labels through the shared catalog; values stay canonical.
        guard provider == .deepseek || provider == .zai || provider == .kiro || provider == .grok else {
            return details.compactMap { section in
                let rows = section.rows.compactMap { row in
                    try? ProviderDetailSection.Row(
                        label: L(row.label),
                        value: row.value,
                        secondaryValue: self.localizedProviderDetailSecondaryValue(row, provider: provider))
                }
                return try? ProviderDetailSection(
                    title: section.title.map(L),
                    rows: rows,
                    chart: section.chart)
            }
        }
        return details.compactMap { section in
            let rows = section.rows.compactMap { row in
                try? ProviderDetailSection.Row(
                    label: L(row.label),
                    value: self.localizedProviderDetailValue(row.value, provider: provider),
                    secondaryValue: row.secondaryValue.map {
                        self.localizedProviderDetailValue($0, provider: provider)
                    })
            }
            let chart = section.chart.flatMap { chart in
                try? ProviderDetailSection.Chart(
                    kind: chart.kind,
                    title: chart.title.map(L),
                    unit: chart.unit.map(L),
                    points: chart.points)
            }
            return try? ProviderDetailSection(
                title: section.title.map(L),
                rows: rows,
                chart: chart)
        }
    }

    private static func localizedProviderDetailSecondaryValue(
        _ row: ProviderDetailSection.Row,
        provider: UsageProvider) -> String?
    {
        // Only this plugin-owned disclosure is copy; arbitrary provider values stay canonical.
        guard provider == .openrouter,
              row.label == "API key limit",
              row.secondaryValue == "Spending cap, not balance"
        else { return row.secondaryValue }
        return L("Spending cap, not balance")
    }

    static func localizedDeepSeekBalanceDescription(_ description: String) -> String {
        let unavailable = "Balance unavailable for API calls"
        if description == unavailable {
            return L(unavailable)
        }

        let addCreditsSeparator = " — add credits at "
        if let range = description.range(of: addCreditsSeparator) {
            return L(
                "%@ — add credits at %@",
                String(description[..<range.lowerBound]),
                String(description[range.upperBound...]))
        }

        let paidSeparator = " (Paid: "
        let grantedSeparator = " / Granted: "
        guard let paidRange = description.range(of: paidSeparator),
              let grantedRange = description.range(
                  of: grantedSeparator,
                  range: paidRange.upperBound..<description.endIndex),
              description.last == ")"
        else {
            return description
        }

        let total = String(description[..<paidRange.lowerBound])
        let paid = String(description[paidRange.upperBound..<grantedRange.lowerBound])
        let granted = String(description[grantedRange.upperBound..<description.index(before: description.endIndex)])
        return L("%@ (Paid: %@ / Granted: %@)", total, paid, granted)
    }

    static func localizedZaiPeriodicResetText(_ window: RateWindow) -> String? {
        guard window.resetsAt == nil,
              window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines) == "5-hour"
        else {
            return nil
        }
        return L("Resets every 5 hours")
    }

    /// Provider-specific by design: DeepSeek, z.ai, Kiro, and Grok detail values carry provider-owned
    /// unit phrasing that localizes at the presentation boundary without touching other providers.
    private static func localizedProviderDetailValue(_ value: String, provider: UsageProvider) -> String {
        switch provider {
        case .deepseek:
            self.localizedTokenSuffix(value)
        case .zai:
            self.localizedZaiValue(value)
        case .kiro:
            self.localizedKiroCapPhrase(value)
        case .grok:
            self.localizedGrokResetValue(value)
        default:
            value
        }
    }

    private static func localizedGrokResetValue(_ value: String) -> String {
        if value == "1 available" {
            return L("1 available")
        }
        let availableSuffix = " available"
        if value.hasSuffix(availableSuffix),
           let count = Int(value.dropLast(availableSuffix.count))
        {
            return L("%d available", count)
        }
        let expiryPrefix = "Expires "
        if value.hasPrefix(expiryPrefix) {
            return L("Expires %@", String(value.dropFirst(expiryPrefix.count)))
        }
        return value
    }

    private static func localizedKiroCapPhrase(_ value: String) -> String {
        let prefix = "of "
        if value.hasPrefix(prefix) {
            return L("of %@", String(value.dropFirst(prefix.count)))
        }
        let suffix = " credits"
        guard value.hasSuffix(suffix) else { return value }
        return "\(String(value.dropLast(suffix.count))) \(L("credits"))"
    }

    private static func localizedTokenSuffix(_ value: String) -> String {
        let suffix = " tokens"
        guard value.hasSuffix(suffix) else { return value }
        return L("%@ tokens", String(value.dropLast(suffix.count)))
    }

    private static func localizedZaiValue(_ value: String) -> String {
        if value == "Peak" || value == "Off-peak" {
            return L(value)
        }
        for rate in ["peak", "off-peak"] {
            let prefix = "\(rate) "
            if value.hasPrefix(prefix) {
                let countdown = String(value.dropFirst(prefix.count))
                return "\(L(rate)) \(self.localizedZaiCountdown(countdown))"
            }
        }

        let usedSuffix = " used"
        if value.hasSuffix(usedSuffix) {
            return L("%@ used", String(value.dropLast(usedSuffix.count)))
        }

        let limitSeparator = " limit · "
        let remainingSuffix = " remaining"
        if let limitRange = value.range(of: limitSeparator),
           value.hasSuffix(remainingSuffix)
        {
            let limit = String(value[..<limitRange.lowerBound])
            let remainingEnd = value.index(value.endIndex, offsetBy: -remainingSuffix.count)
            let remaining = String(value[limitRange.upperBound..<remainingEnd])
            return L("%@ limit · %@ remaining", limit, remaining)
        }

        let limitSuffix = " limit"
        if value.hasSuffix(limitSuffix) {
            return L("%@ limit", String(value.dropLast(limitSuffix.count)))
        }
        if value.hasSuffix(remainingSuffix) {
            return L("%@ remaining", String(value.dropLast(remainingSuffix.count)))
        }
        return value
    }

    private static func localizedZaiCountdown(_ value: String) -> String {
        guard value.hasPrefix("in ") else { return L(value) }
        let parts = value.dropFirst(3).split(separator: " ").map(String.init)
        if parts.count == 2 {
            let first = parts[0]
            let second = parts[1]
            if first.hasSuffix("d"), second.hasSuffix("h") {
                return L("in %@d %@h", String(first.dropLast()), String(second.dropLast()))
            }
            if first.hasSuffix("d"), second.hasSuffix("m") {
                return L("in %@d %@m", String(first.dropLast()), String(second.dropLast()))
            }
            if first.hasSuffix("h"), second.hasSuffix("m") {
                return L("in %@h %@m", String(first.dropLast()), String(second.dropLast()))
            }
        }
        if parts.count == 1 {
            let part = parts[0]
            if part.hasSuffix("d") {
                return L("in %@d", String(part.dropLast()))
            }
            if part.hasSuffix("h") {
                return L("in %@h", String(part.dropLast()))
            }
            if part.hasSuffix("m") {
                return L("in %@m", String(part.dropLast()))
            }
        }
        return value
    }
}
