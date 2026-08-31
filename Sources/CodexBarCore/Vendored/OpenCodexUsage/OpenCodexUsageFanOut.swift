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
        for entry in entries {
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

    public static func mergeSnapshots(
        _ base: CostUsageTokenSnapshot,
        _ supplement: CostUsageTokenSnapshot,
        now: Date,
        historyDays: Int,
        calendar: Calendar) -> CostUsageTokenSnapshot
    {
        let mergedReport = CostUsageDailyReport.merged([
            CostUsageDailyReport(
                data: base.daily,
                summary: nil,
                hourly: base.hourly,
                quotaSlices: base.quotaSlices),
            CostUsageDailyReport(
                data: supplement.daily,
                summary: nil,
                hourly: supplement.hourly,
                quotaSlices: supplement.quotaSlices),
        ], calendar: calendar)
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
            projects: projects,
            sessions: sessions,
            updatedAt: max(base.updatedAt, supplement.updatedAt))
    }
}
