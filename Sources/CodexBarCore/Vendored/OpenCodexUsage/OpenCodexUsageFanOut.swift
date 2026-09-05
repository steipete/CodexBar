import Foundation

public enum OpenCodexUsageFanOut {
    public static func snapshotsBySubscription(
        entries: [OpenCodexUsageEntry],
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        customPricing: CostUsageCustomPricing = .empty) -> [UsageProvider: CostUsageTokenSnapshot]
    {
        var grouped: [UsageProvider: [OpenCodexUsageEntry]] = [:]
        let latest = Dictionary(entries.map { ($0.requestID, $0) }, uniquingKeysWith: { _, latest in latest })
        for entry in latest.values {
            let grokAttempts = self.grokOAuthEntries(from: entry)
            if !grokAttempts.isEmpty {
                // Provider-specific by design: each OAuth attempt contributes only its own reported Grok usage.
                grouped[.grok, default: []].append(contentsOf: grokAttempts)
            }
            if entry.provider == "xai" || entry.provider == "combo" { continue }
            guard case let .subscription(provider) = OpenCodexRouteDispatcher.route(
                provider: entry.provider,
                modelName: entry.model)
            else {
                continue
            }
            grouped[provider, default: []].append(entry)
        }
        guard !grouped.isEmpty else { return [:] }
        // Resolve the models.dev catalog and the custom-pricing overlay once for all providers; each snapshot then
        // prices its entries against this shared context instead of re-reading both per pricing call (see
        // `OpenCodexUsageAggregator.snapshot`). A missing catalog is passed as an empty one for the same reason.
        let catalog = CostUsagePricing.modelsDevCatalog() ?? ModelsDevCatalog(providers: [:])
        let overlay = CostUsagePricing.customPricingOverlay()
        return grouped.mapValues { providerEntries in
            OpenCodexUsageAggregator.snapshot(
                entries: providerEntries,
                now: now,
                historyDays: historyDays,
                calendar: calendar,
                customPricing: customPricing,
                modelsDevCatalog: catalog,
                customPricingOverlay: overlay)
        }
    }

    static func grokOAuthEntries(from entry: OpenCodexUsageEntry) -> [OpenCodexUsageEntry] {
        // Provider-specific by design: only physical xAI attempts from xAI or combo parents can prove Grok usage.
        guard entry.provider == "xai" || entry.provider == "combo" else { return [] }
        // Duplicate ordinals are ambiguous. Drop every copy rather than selecting whichever came first.
        let ordinals = Dictionary(grouping: entry.attempts, by: \.ordinal)
        return entry.attempts.compactMap { attempt in
            guard ordinals[attempt.ordinal]?.count == 1,
                  attempt.provider == "xai", attempt.credentialSource == .grokOAuth,
                  attempt.sendCount > 0, !attempt.locallyAnswered, attempt.usageStatus == .reported,
                  attempt.usage != nil,
                  !attempt.model.contains("/") || attempt.model.hasPrefix("xai/")
            else { return nil }
            return OpenCodexUsageEntry(parent: entry, attempt: attempt)
        }
    }

    public static func mergeSnapshots(
        _ base: CostUsageTokenSnapshot,
        _ supplement: CostUsageTokenSnapshot,
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        provider: UsageProvider? = nil) -> CostUsageTokenSnapshot
    {
        let mergedReport = CostUsageDailyReport.merged([
            CostUsageDailyReport(data: base.daily, summary: nil),
            CostUsageDailyReport(data: supplement.daily, summary: nil),
        ])
        var sessions = base.sessions
        var sessionIDs = Set(sessions.map(\.id))
        for session in supplement.sessions where sessionIDs.insert(session.id).inserted {
            sessions.append(session)
        }
        var projects = base.projects
        var projectNames = Set(projects.map(\.name))
        for project in supplement.projects where projectNames.insert(project.name).inserted {
            projects.append(project)
        }
        return CostUsageFetcher.tokenSnapshot(
            from: mergedReport,
            now: now,
            historyDays: max(base.historyDays, supplement.historyDays, historyDays),
            calendar: calendar,
            historyCoverageIsEstablished: base.historyCoverageIsEstablished
                && supplement.historyCoverageIsEstablished,
            // Provider-specific by design: Grok recorded and OpenCodex estimated rows retain distinct coverage.
            costProvenance: provider == .grok
                ? GrokLocalSessionSummary.costProvenance(for: mergedReport.data, fallback: .mixed)
                : .unknown,
            projects: projects,
            sessions: sessions,
            updatedAt: max(base.updatedAt, supplement.updatedAt))
    }
}
