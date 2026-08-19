import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func localizedProviderDetails(
        _ details: [ProviderDetailSection],
        provider: UsageProvider) -> [ProviderDetailSection]
    {
        details.compactMap { section in
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

    static func localizedDeepSeekBalanceDescription(_ description: String) -> String {
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

    private static func localizedProviderDetailValue(_ value: String, provider: UsageProvider) -> String {
        switch provider {
        case .deepseek:
            self.localizedTokenSuffix(value)
        case .zai:
            self.localizedZaiValue(value)
        default:
            value
        }
    }

    private static func localizedTokenSuffix(_ value: String) -> String {
        let suffix = " tokens"
        guard value.hasSuffix(suffix) else { return value }
        return L("%@ tokens", String(value.dropLast(suffix.count)))
    }

    private static func localizedZaiValue(_ value: String) -> String {
        let usedSuffix = " used"
        if value.hasSuffix(usedSuffix) {
            return L("%@ used", String(value.dropLast(usedSuffix.count)))
        }

        let limitSeparator = " limit · "
        let remainingSuffix = " remaining"
        guard let limitRange = value.range(of: limitSeparator),
              value.hasSuffix(remainingSuffix)
        else {
            return value
        }
        let limit = String(value[..<limitRange.lowerBound])
        let remainingEnd = value.index(value.endIndex, offsetBy: -remainingSuffix.count)
        let remaining = String(value[limitRange.upperBound..<remainingEnd])
        return L("%@ limit · %@ remaining", limit, remaining)
    }
}
