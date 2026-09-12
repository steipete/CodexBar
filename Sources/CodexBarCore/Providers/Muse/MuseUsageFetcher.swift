import Foundation

public enum MuseUsageError: LocalizedError, Sendable, Equatable {
    /// None of the candidate session directories exist.
    case sessionLogsUnavailable(searched: [String])
    /// A session directory exists but holds no readable session log records.
    case noSessionLogs(searched: [String])

    public var errorDescription: String? {
        switch self {
        case let .sessionLogsUnavailable(searched):
            "No Muse Code session directory found (looked in \(searched.joined(separator: ", "))). " +
                "Run Muse Code once, or point MUSE_SESSIONS_DIR at its sessions folder."
        case let .noSessionLogs(searched):
            "No readable Muse Code session logs found in \(searched.joined(separator: ", "))."
        }
    }
}

/// Local Muse Code telemetry: token totals read from session logs. This deliberately reports no quota
/// windows — Meta publishes no local-derivable limits, so remaining-capacity bars would be invented.
/// Subscription windows belong to an authoritative account source; cost comes from the token snapshot.
public struct MuseUsageFetcher: Sendable {
    struct TokenTotals: Equatable {
        var todayTokens = 0
        var weeklyTokens = 0
        /// Files that yielded at least one decodable record, even when none carried model usage.
        var readableFileCount = 0
    }

    public static func fetchUsage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sessionRoots: [URL]? = nil,
        configURL: URL? = nil,
        now: Date = Date(),
        calendar: Calendar = .current) async throws -> UsageSnapshot
    {
        let settings = MuseSettingsReader.readSettings(environment: environment, configURL: configURL)
        let roots = sessionRoots ?? MuseSettingsReader.defaultSessionRoots(environment: environment)
        let existingRoots = roots.filter { Self.isDirectory($0) }
        guard !existingRoots.isEmpty else {
            throw MuseUsageError.sessionLogsUnavailable(searched: roots.map(\.path))
        }

        let totals = try Self.recentTokenTotals(
            roots: existingRoots,
            now: now,
            isContributor: settings.isContributor,
            calendar: calendar)
        guard totals.readableFileCount > 0 else {
            throw MuseUsageError.noSessionLogs(searched: existingRoots.map(\.path))
        }

        let summary = "today \(UsageFormatter.tokenCountString(totals.todayTokens)) · " +
            "7d \(UsageFormatter.tokenCountString(totals.weeklyTokens))"
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: settings.email,
            accountOrganization: settings.planName,
            loginMethod: summary)

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Sums tokens per local calendar day using the same parser as the cost scanner, so undated or
    /// malformed records are rejected identically in both surfaces. The window is today plus the six
    /// preceding local days; rows the parser returns from its one-day scan padding are filtered out.
    static func recentTokenTotals(
        roots: [URL],
        now: Date,
        isContributor: Bool,
        calendar: Calendar) throws -> TokenTotals
    {
        let windowStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        let range = CostUsageScanner.CostUsageDayRange(since: windowStart, until: now, calendar: calendar)
        let todayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: now, calendar: calendar)
        var totals = TokenTotals()

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "json" || ext == "jsonl" else { continue }

                let parsed = try CostUsageScanner.parseMuseFileCancellable(
                    fileURL: fileURL,
                    range: range,
                    isContributor: isContributor)
                if parsed.decodedRecordCount > 0 {
                    totals.readableFileCount += 1
                }
                for row in parsed.rows where CostUsageScanner.CostUsageDayRange.isInRange(
                    dayKey: row.dayKey,
                    since: range.sinceKey,
                    until: range.untilKey)
                {
                    let (rowTotal, rowOverflow) = row.input.addingReportingOverflow(row.output)
                    guard !rowOverflow else { continue }
                    let (weekly, weeklyOverflow) = totals.weeklyTokens.addingReportingOverflow(rowTotal)
                    guard !weeklyOverflow else { continue }
                    totals.weeklyTokens = weekly
                    if row.dayKey == todayKey {
                        let (today, todayOverflow) = totals.todayTokens.addingReportingOverflow(rowTotal)
                        if !todayOverflow { totals.todayTokens = today }
                    }
                }
            }
        }
        return totals
    }
}
