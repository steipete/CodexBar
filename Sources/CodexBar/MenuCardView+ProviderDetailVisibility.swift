import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func visibleProviderDetails(
        input: Input,
        replacedRows: [String: Set<String>]) -> (sections: [ProviderDetailSection], rawTitles: [String?])
    {
        var details = input.snapshot?.details ?? []
        if !replacedRows.isEmpty {
            details = details.compactMap { section in
                guard let title = section.title, let labels = replacedRows[title] else { return section }
                let rows = section.rows.filter { !labels.contains($0.label) }
                guard !rows.isEmpty || section.chart != nil else { return nil }
                return try? ProviderDetailSection(title: section.title, rows: rows, chart: section.chart)
            }
        }
        let policy = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.optionalDetails
        if !input.costSummaryInlineEnabled, !policy.costSummaryTitles.isEmpty {
            details.removeAll { section in
                section.title.map(policy.costSummaryTitles.contains) == true
            }
        }
        if !input.showOptionalCreditsAndExtraUsage {
            if policy.hidesAllWithoutOptionalUsage {
                details = []
            } else if !policy.hiddenTitlesWithoutOptionalUsage.isEmpty {
                details.removeAll { section in
                    section.title.map(policy.hiddenTitlesWithoutOptionalUsage.contains) == true
                }
            }
        }
        // Provider-specific by design: Grok removes migrated reset rows; Sub2API localizes its usage details.
        if input.provider == .grok {
            details = details.compactMap { section in
                let rows = section.rows.filter { $0.label != "Limit Reset Credits" }
                guard !rows.isEmpty || section.chart != nil else { return nil }
                return try? ProviderDetailSection(title: section.title, rows: rows, chart: section.chart)
            }
        }
        let pairs = details.flatMap { rawSection in
            let localized = input.provider == .sub2api
                ? Self.sub2APILocalizedDetails([rawSection]) : [rawSection]
            return Self.localizedProviderDetails(localized, provider: input.provider).map {
                (section: $0, rawTitle: rawSection.title)
            }
        }
        let visible = pairs.compactMap { pair -> (section: ProviderDetailSection, rawTitle: String?)? in
            guard input.hidePersonalInfo else { return pair }
            let section = pair.section
            let rows = section.rows.compactMap { row in
                try? ProviderDetailSection.Row(
                    id: row.id,
                    label: PersonalInfoRedactor.redactEmails(in: row.label, isEnabled: true) ?? row.label,
                    value: PersonalInfoRedactor.redactEmails(in: row.value, isEnabled: true) ?? row.value,
                    secondaryValue: PersonalInfoRedactor.redactEmails(
                        in: row.secondaryValue,
                        isEnabled: true),
                    progress: row.progress,
                    usageValue: row.usageValue)
            }
            let chart = section.chart.flatMap { chart in
                let points = chart.points.compactMap { point in
                    try? ProviderDetailSection.Chart.Point(
                        label: PersonalInfoRedactor.redactEmails(in: point.label, isEnabled: true) ?? point.label,
                        value: point.value)
                }
                return try? ProviderDetailSection.Chart(
                    kind: chart.kind,
                    title: PersonalInfoRedactor.redactEmails(in: chart.title, isEnabled: true),
                    unit: chart.unit,
                    points: points)
            }
            let redacted = try? ProviderDetailSection(
                title: PersonalInfoRedactor.redactEmails(in: section.title, isEnabled: true),
                rows: rows,
                chart: chart)
            return redacted.map { (section: $0, rawTitle: pair.rawTitle) }
        }
        return (visible.map(\.section), visible.map(\.rawTitle))
    }
}
