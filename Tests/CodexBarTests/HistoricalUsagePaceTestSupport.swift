import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension HistoricalUsagePaceTests {
    private static let utcTimeZone: TimeZone = {
        if let zone = TimeZone(identifier: "UTC") {
            return zone
        }
        if let zone = TimeZone(secondsFromGMT: 0) {
            return zone
        }
        return TimeZone.current
    }()

    static func linearCurve(end: Double) -> [Double] {
        let clampedEnd = max(0, min(100, end))
        let count = CodexHistoricalDataset.gridPointCount
        return (0..<count).map { index in
            let u = Double(index) / Double(count - 1)
            return clampedEnd * u
        }
    }

    static func outlierCurve() -> [Double] {
        let count = CodexHistoricalDataset.gridPointCount
        return (0..<count).map { index in
            let u = Double(index) / Double(count - 1)
            return min(100, 80 + (20 * u))
        }
    }

    static func makeTempURL() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-historical-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return root.appendingPathComponent("usage-history.jsonl", isDirectory: false)
    }

    static func syntheticBreakdown(
        endingAt endDate: Date,
        days: Int,
        dailyCredits: Double,
        overridesByDayOffset: [Int: Double] = [:]) -> [OpenAIDashboardDailyBreakdown]
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utcTimeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Self.utcTimeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let endDay = calendar.startOfDay(for: endDate)
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: endDay) else { return nil }
            let day = formatter.string(from: date)
            let credits = overridesByDayOffset[offset] ?? dailyCredits
            return OpenAIDashboardDailyBreakdown(
                day: day,
                services: [OpenAIDashboardServiceUsage(service: "CLI", creditsUsed: credits)],
                totalCreditsUsed: credits)
        }
    }

    static func gregorianDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utcTimeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = Self.utcTimeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        guard let date = calendar.date(from: components) else {
            preconditionFailure("Invalid Gregorian date components")
        }
        return date
    }

    static func dayStart(for key: String) -> Date? {
        let components = key.split(separator: "-", omittingEmptySubsequences: true)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2])
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utcTimeZone
        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.timeZone = Self.utcTimeZone
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        return calendar.date(from: dateComponents)
    }

    static func normalizeReset(_ value: Date) -> Date {
        let bucket = 60.0
        let rounded = (value.timeIntervalSinceReferenceDate / bucket).rounded() * bucket
        return Date(timeIntervalSinceReferenceDate: rounded)
    }

    static func readHistoricalRecords(from fileURL: URL) throws -> [HistoricalUsageRecord] {
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(HistoricalUsageRecord.self, from: Data(line.utf8))
            }
    }

    static func recordDedupKeyCount(_ records: [HistoricalUsageRecord]) -> Int {
        struct Key: Hashable {
            let resetsAt: Date
            let sampledAt: Date
            let windowMinutes: Int
            let accountKey: String?
        }
        let keys = records.map { record in
            Key(
                resetsAt: record.resetsAt,
                sampledAt: record.sampledAt,
                windowMinutes: record.windowMinutes,
                accountKey: record.accountKey)
        }
        return Set(keys).count
    }

    static func datasetCurveSignature(_ dataset: CodexHistoricalDataset?) -> String {
        guard let dataset else { return "nil" }
        return dataset.weeks
            .sorted { lhs, rhs in lhs.resetsAt < rhs.resetsAt }
            .map { week in
                let curve = week.curve.map { String(format: "%.4f", $0) }.joined(separator: ",")
                return "\(week.resetsAt.timeIntervalSinceReferenceDate)|\(week.windowMinutes)|\(curve)"
            }
            .joined(separator: "||")
    }

    @MainActor
    static func makeUsageStoreForBackfillTests(suite: String, historyFileURL: URL) throws -> UsageStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.historicalTrackingEnabled = true
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: historyFileURL))
    }
}
