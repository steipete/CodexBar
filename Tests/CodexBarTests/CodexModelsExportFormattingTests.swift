import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite("Codex Models export and formatting")
struct CodexModelsExportFormattingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    @Test
    func `CSV export uses raw precision and explicit unknown cost`() {
        let intervals = self.intervals(days: 7)
        let current = [self.fragment(
            day: intervals.current.start,
            model: "model,quoted",
            input: 7_100_000_000,
            costNanos: nil)]
        let snapshot = self.build(current: current, previous: [], intervals: intervals, legacyTotal: 7_100_000_000)
        let csv = CodexModelsCSVExporter.export(snapshot: snapshot)

        #expect(csv.contains("7100000000"))
        #expect(!csv.contains("7.1B"))
        #expect(csv.contains(",0,7100000000,"))
        #expect(csv.contains("\"model,quoted\""))
        #expect(csv.contains(",unavailable,"))
    }

    @Test
    func `CSV export keeps previous unavailable pricing blank and auditable`() throws {
        let intervals = self.intervals(days: 7)
        let snapshot = self.build(
            current: [self.fragment(
                day: intervals.current.start,
                model: "model-a",
                input: 10,
                costNanos: 1_000_000_000)],
            previous: [self.fragment(
                day: intervals.previous.start,
                model: "model-a",
                input: 8,
                costNanos: nil)],
            intervals: intervals,
            legacyTotal: 10)

        let lines = CodexModelsCSVExporter.export(snapshot: snapshot).split(separator: "\n")
        let header = try #require(lines.first).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let values = try #require(lines.dropFirst().first)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        let fields = Dictionary(uniqueKeysWithValues: zip(header, values))

        #expect(fields["reasoning_tokens"]?.isEmpty == true)
        #expect(fields["previous_known_cost"]?.isEmpty == true)
        #expect(fields["previous_cost_status"] == "unavailable")
        #expect(fields["previous_cost_coverage"] == "0")
        #expect(fields["previous_priced_tokens"] == "0")
        #expect(fields["previous_unpriced_tokens"] == "8")
    }

    private func build(
        current: [CodexModelsUsageFragment],
        previous: [CodexModelsUsageFragment],
        intervals: (current: DateInterval, previous: DateInterval),
        legacyTotal: Int64) -> CodexModelsAnalyticsSnapshot
    {
        CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: current, previous: previous),
            scopeID: nil,
            periods: CodexModelsAnalyticsPeriods(current: intervals.current, previous: intervals.previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: intervals.current.end, indexRevision: "fixture"),
            legacy: CodexModelsLegacyBaseline(
                totalTokens: legacyTotal,
                modelIDs: Array(Set(current.map(\.rawModelID))))))
    }

    private func intervals(days: Int) -> (current: DateInterval, previous: DateInterval) {
        let end = self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16))!
        let currentStart = self.calendar.date(byAdding: .day, value: -days, to: end)!
        let previousStart = self.calendar.date(byAdding: .day, value: -days, to: currentStart)!
        return (
            DateInterval(start: currentStart, end: end),
            DateInterval(start: previousStart, end: currentStart))
    }

    private func fragment(
        day: Date,
        model: String,
        input: Int64,
        costNanos: Int64?) -> CodexModelsUsageFragment
    {
        CodexModelsUsageFragment(
            workspaceID: "workspace",
            sessionID: "session",
            day: day,
            rawModelID: model,
            inputTokens: input,
            cachedInputTokens: min(3, input),
            outputTokens: 0,
            costNanos: costNanos)
    }
}
