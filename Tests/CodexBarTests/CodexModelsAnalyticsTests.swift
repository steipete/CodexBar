import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite("Codex Models analytics")
struct CodexModelsAnalyticsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    @Test
    func `canonical aliases merge while raw aliases remain auditable`() {
        let intervals = self.intervals(days: 7)
        let current = [
            self.fragment(day: intervals.current.start, model: "GPT-5", input: 10, output: 2, session: "one"),
            self.fragment(day: intervals.current.start, model: "gpt-5", input: 7, output: 1, session: "two"),
            self.fragment(day: intervals.current.start, model: " OpenAI/GPT-5 ", input: 3, output: 0, session: "three"),
        ]
        let snapshot = self.build(current: current, previous: [], intervals: intervals, legacyTotal: 23)

        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].id == "gpt-5")
        #expect(snapshot.rows[0].rawAliases == [" OpenAI/GPT-5 ", "GPT-5", "gpt-5"])
        #expect(snapshot.rows[0].sessionReferences == 3)
        #expect(snapshot.rows[0].associatedSessionIDs == ["one", "three", "two"])
    }

    @Test
    func `cached input and reasoning detail are not double counted`() {
        let intervals = self.intervals(days: 7)
        let fragment = CodexModelsUsageFragment(
            workspaceID: "workspace",
            sessionID: "one",
            day: intervals.current.start,
            rawModelID: "model-a",
            inputTokens: 100,
            cachedInputTokens: 80,
            outputTokens: 40,
            reasoningTokens: 30,
            costNanos: 1_500_000_000)
        let snapshot = self.build(current: [fragment], previous: [], intervals: intervals, legacyTotal: 140)
        let row = snapshot.rows[0]

        #expect(row.totalTokens == 140)
        #expect(row.cachedInputTokens == 80)
        #expect(row.reasoningTokens == 30)
        #expect(snapshot.invariantViolations().isEmpty)
    }

    @Test
    func `pricing distinguishes complete partial unavailable and known zero`() throws {
        let intervals = self.intervals(days: 7)
        let current = [
            self.fragment(day: intervals.current.start, model: "model-a", input: 10, output: 0, costNanos: 0),
            self.fragment(day: intervals.current.start, model: "model-b", input: 20, output: 0, costNanos: nil),
            CodexModelsUsageFragment(
                workspaceID: "workspace",
                sessionID: "partial",
                day: intervals.current.start,
                rawModelID: "model-a",
                inputTokens: 25,
                cachedInputTokens: 0,
                outputTokens: 0,
                costNanos: 250_000_000,
                unpricedTokens: 20),
        ]
        let snapshot = self.build(current: current, previous: [], intervals: intervals, legacyTotal: 55)
        let priced = try #require(snapshot.rows.first { $0.id == "model-a" })
        let unavailable = try #require(snapshot.rows.first { $0.id == "model-b" })

        #expect(priced.cost.knownAmount == Decimal(string: "0.25"))
        #expect(priced.cost.pricedTokens == 15)
        #expect(priced.cost.unpricedTokens == 20)
        #expect(unavailable.cost.knownAmount == 0)
        #expect(unavailable.cost.pricedTokens == 0)
        #expect(unavailable.cost.unpricedTokens == 20)
        #expect(snapshot.cost.pricedTokens + snapshot.cost.unpricedTokens == snapshot.totalTokens)
    }

    @Test
    func `current and previous periods are equal duration across DST`() throws {
        let end = try #require(self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 12)))
        let currentStart = try #require(self.calendar.date(byAdding: .day, value: -7, to: end))
        let currentInterval = DateInterval(start: currentStart, end: end)
        let previousStart = currentStart.addingTimeInterval(-currentInterval.duration)
        let intervals = (
            current: currentInterval,
            previous: DateInterval(start: previousStart, end: currentStart))
        let current = [self.fragment(day: currentStart, model: "model-a", input: 20, output: 0)]
        let previous = [self.fragment(day: previousStart, model: "model-a", input: 10, output: 0)]
        let snapshot = self.build(current: current, previous: previous, intervals: intervals, legacyTotal: 20)

        #expect(intervals.current.duration == intervals.previous.duration)
        #expect(snapshot.rows[0].tokenComparison == .percent(1))
    }

    @Test
    func `indexer periods are adjacent equal seconds across both DST transitions`() throws {
        let springSince = try #require(self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 6)))
        let springUntil = try #require(self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 12)))
        let fallSince = try #require(self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30)))
        let fallUntil = try #require(self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))

        for periods in [
            CodexLocalProjectUsageIndexer.modelsAnalyticsPeriods(
                since: springSince,
                until: springUntil,
                calendar: self.calendar),
            CodexLocalProjectUsageIndexer.modelsAnalyticsPeriods(
                since: fallSince,
                until: fallUntil,
                calendar: self.calendar),
        ] {
            #expect(periods.current.duration == periods.previous.duration)
            #expect(periods.previous.end == periods.current.start)
        }

        let fallPeriods = CodexLocalProjectUsageIndexer.modelsAnalyticsPeriods(
            since: fallSince,
            until: fallUntil,
            calendar: self.calendar)
        let scanStart = CodexLocalProjectUsageIndexer.modelsAnalyticsScanStart(
            since: fallSince,
            until: fallUntil,
            calendar: self.calendar)
        let calendarDaySubtraction = try #require(
            self.calendar.date(byAdding: .day, value: -7, to: fallPeriods.current.start))
        #expect(calendarDaySubtraction > fallPeriods.previous.start)
        #expect(scanStart <= fallPeriods.previous.start)
        #expect(fallPeriods.previous.start.timeIntervalSince(scanStart) < 24 * 60 * 60)
    }

    @Test
    func `timestamp filtering uses half open current and previous boundaries`() {
        let intervals = self.intervals(days: 2)
        let current = [
            self.fragment(
                day: intervals.current.start,
                timestamp: intervals.current.start,
                model: "model-a",
                input: 10,
                output: 0),
            self.fragment(
                day: intervals.current.start,
                timestamp: intervals.current.end.addingTimeInterval(-0.001),
                model: "model-a",
                input: 20,
                output: 0),
            self.fragment(
                day: intervals.current.end,
                timestamp: intervals.current.end,
                model: "model-a",
                input: 40,
                output: 0),
        ]
        let previous = [
            self.fragment(
                day: intervals.previous.start,
                timestamp: intervals.previous.start,
                model: "model-a",
                input: 5,
                output: 0),
            self.fragment(
                day: intervals.previous.start,
                timestamp: intervals.previous.end.addingTimeInterval(-0.001),
                model: "model-a",
                input: 7,
                output: 0),
            self.fragment(
                day: intervals.previous.end,
                timestamp: intervals.previous.end,
                model: "model-a",
                input: 9,
                output: 0),
        ]
        let snapshot = self.build(current: current, previous: previous, intervals: intervals, legacyTotal: 30)

        #expect(snapshot.totalTokens == 30)
        #expect(snapshot.rows[0].previousTotalTokens == 12)
        #expect(snapshot.rows[0].tokenComparison == .percent(1.5))
    }

    @Test
    func `session references count distinct session model pairs`() throws {
        let intervals = self.intervals(days: 7)
        let secondDay = try #require(self.calendar.date(byAdding: .day, value: 1, to: intervals.current.start))
        let current = [
            self.fragment(day: intervals.current.start, model: "model-a", input: 1, output: 0, session: "same"),
            self.fragment(day: secondDay, model: "model-a", input: 1, output: 0, session: "same"),
            self.fragment(day: secondDay, model: "model-b", input: 1, output: 0, session: "same"),
        ]
        let snapshot = self.build(current: current, previous: [], intervals: intervals, legacyTotal: 3)

        #expect(snapshot.uniqueSessionCount == 1)
        #expect(snapshot.sessionReferenceTotal == 2)
        #expect(snapshot.rows.first { $0.id == "model-a" }?.sessionReferences == 1)
        #expect(snapshot.rows.first { $0.id == "model-b" }?.sessionReferences == 1)
        let allModelsBucket = try #require(snapshot.daily.last)
        #expect(allModelsBucket.sessionIDs == ["same"])
        #expect(allModelsBucket.sessionReferenceIDs.count == 2)
        #expect(allModelsBucket.sessionReferences == 2)
        #expect(snapshot.dailyByModel["model-a"]?.last?.sessionReferences == 1)
        #expect(snapshot.dailyByModel["model-b"]?.last?.sessionReferences == 1)
    }

    @Test
    func `incomplete previous coverage suppresses comparisons and newly active semantics`() {
        let intervals = self.intervals(days: 7)
        let current = [
            self.fragment(day: intervals.current.start, model: "model-a", input: 20, output: 0, session: "one"),
            self.fragment(day: intervals.current.start, model: "model-b", input: 10, output: 0, session: "two"),
        ]
        let previous = [
            self.fragment(day: intervals.previous.start, model: "model-a", input: 10, output: 0, session: "old"),
        ]
        let complete = self.build(current: current, previous: previous, intervals: intervals, legacyTotal: 30)
        let incomplete = self.build(
            current: current,
            previous: previous,
            intervals: intervals,
            legacyTotal: 30,
            previousIsComplete: false)

        #expect(complete.previousActiveModelCount == 1)
        #expect(complete.newlyActiveModelCount == 1)
        #expect(complete.rows.first { $0.id == "model-a" }?.previousTotalTokens == 10)

        #expect(incomplete.currentIsComplete == true)
        #expect(incomplete.previousIsComplete == false)
        #expect(incomplete.previousActiveModelCount == nil)
        #expect(incomplete.newlyActiveModelCount == nil)
        #expect(incomplete.previousSessionReferenceTotal == nil)
        #expect(incomplete.tokenComparison == .unavailable)
        #expect(incomplete.costComparison == .unavailable)
        #expect(incomplete.sessionReferenceComparison == .unavailable)
        for row in incomplete.rows {
            #expect(row.previousTotalTokens == nil)
            #expect(row.previousCost == nil)
            #expect(row.previousSessionReferences == nil)
            #expect(row.tokenComparison == .unavailable)
            #expect(row.costComparison == .unavailable)
            #expect(row.sessionReferenceComparison == .unavailable)
        }
    }

    @Test
    func `ranking ties are deterministic`() {
        let intervals = self.intervals(days: 7)
        let current = [
            self.fragment(day: intervals.current.start, model: "model-z", input: 10, output: 0),
            self.fragment(day: intervals.current.start, model: "model-a", input: 10, output: 0),
        ]
        let snapshot = self.build(current: current, previous: [], intervals: intervals, legacyTotal: 20)
        #expect(snapshot.rows.map(\.id) == ["model-a", "model-z"])
    }

    @Test
    func `dual run diagnostics flag total and identity mismatches`() {
        let intervals = self.intervals(days: 7)
        let current = [self.fragment(day: intervals.current.start, model: "model-a", input: 10, output: 0)]
        let snapshot = CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: current, previous: []),
            scopeID: nil,
            periods: CodexModelsAnalyticsPeriods(current: intervals.current, previous: intervals.previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: intervals.current.end, indexRevision: "fixture"),
            legacy: CodexModelsLegacyBaseline(totalTokens: 11, modelIDs: ["model-b"])))

        #expect(snapshot.diagnostics.mismatches == ["total_tokens", "model_identities"])
        #expect(snapshot.diagnostics.mismatchDimensions == [.totalTokens, .modelIdentities])
    }

    @Test
    func `dual run diagnostics compare current and previous per model raw values`() {
        let intervals = self.intervals(days: 7)
        let current = [self.fragment(
            day: intervals.current.start,
            model: "model-a",
            input: 10,
            output: 0,
            session: "current",
            costNanos: 100_000_000)]
        let previous = [self.fragment(
            day: intervals.previous.start,
            model: "model-a",
            input: 5,
            output: 0,
            session: "previous",
            costNanos: 200_000_000)]
        let snapshot = CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: current, previous: previous),
            scopeID: nil,
            periods: CodexModelsAnalyticsPeriods(current: intervals.current, previous: intervals.previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: intervals.current.end, indexRevision: "fixture"),
            legacy: CodexModelsLegacyBaseline(
                totalTokens: 10,
                modelIDs: ["model-a"],
                currentModels: [CodexModelsLegacyModelBaseline(
                    modelID: "model-a",
                    totalTokens: 11,
                    knownCost: Decimal(string: "0.3"),
                    pricedTokens: 10,
                    unpricedTokens: 0,
                    sessionReferences: 1)],
                previousModels: [CodexModelsLegacyModelBaseline(
                    modelID: "model-a",
                    totalTokens: 5,
                    knownCost: Decimal(string: "0.2"),
                    pricedTokens: 0,
                    unpricedTokens: 5,
                    sessionReferences: 2)])))

        #expect(snapshot.diagnostics.mismatchDimensions == [
            .modelTokens,
            .modelKnownCost,
            .modelPricingCoverage,
            .modelSessionReferences,
        ])
    }

    @Test
    func `per model parity canonicalizes aliases and preserves unavailable pricing`() {
        let intervals = self.intervals(days: 7)
        let current = [
            self.fragment(
                day: intervals.current.start,
                model: "GPT-5",
                input: 6,
                output: 0,
                session: "same",
                costNanos: nil),
            self.fragment(
                day: intervals.current.start,
                model: "gpt-5",
                input: 4,
                output: 0,
                session: "same",
                costNanos: nil),
        ]
        let previous = [self.fragment(
            day: intervals.previous.start,
            model: "OpenAI/GPT-5",
            input: 5,
            output: 0,
            session: "earlier",
            costNanos: nil)]
        let snapshot = CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: current, previous: previous),
            scopeID: nil,
            periods: CodexModelsAnalyticsPeriods(current: intervals.current, previous: intervals.previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: intervals.current.end, indexRevision: "fixture"),
            legacy: CodexModelsLegacyBaseline(
                totalTokens: 10,
                modelIDs: ["gpt-5"],
                currentModels: [CodexModelsLegacyModelBaseline(
                    modelID: "gpt-5",
                    totalTokens: 10,
                    pricedTokens: 0,
                    unpricedTokens: 10,
                    sessionReferences: 1)],
                previousModels: [CodexModelsLegacyModelBaseline(
                    modelID: "gpt-5",
                    totalTokens: 5,
                    pricedTokens: 0,
                    unpricedTokens: 5,
                    sessionReferences: 1)])))

        #expect(snapshot.diagnostics.isMatched)
        #expect(snapshot.rows[0].sessionReferences == 1)
        #expect(snapshot.rows[0].cost.pricedTokens == 0)
        #expect(snapshot.rows[0].cost.unpricedTokens == 10)
    }

    @Test
    func `per model parity skips periods whose source coverage is incomplete`() {
        let intervals = self.intervals(days: 7)
        let current = [self.fragment(day: intervals.current.start, model: "model-a", input: 10, output: 0)]
        let snapshot = CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: current, previous: []),
            scopeID: nil,
            periods: CodexModelsAnalyticsPeriods(current: intervals.current, previous: intervals.previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: intervals.current.end, indexRevision: "fixture"),
            legacy: CodexModelsLegacyBaseline(
                totalTokens: 10,
                modelIDs: ["model-a"],
                currentModels: [CodexModelsLegacyModelBaseline(
                    modelID: "model-a",
                    totalTokens: 99,
                    knownCost: 99,
                    pricedTokens: 0,
                    unpricedTokens: 99,
                    sessionReferences: 99)]),
            currentIsComplete: false,
            previousIsComplete: true))

        #expect(snapshot.diagnostics.isMatched)
    }

    @Test
    func `legacy event rows decode without new timestamp or pricing audit fields`() throws {
        let data = Data("""
        {
          "day": "2026-07-16",
          "model": "model-a",
          "turnID": "turn-1",
          "eventIndex": 4,
          "input": 10,
          "cached": 3,
          "output": 2
        }
        """.utf8)
        let row = try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: data)

        #expect(row.rawModel == nil)
        #expect(row.timestampUnixMs == nil)
        #expect(row.knownCostNanos == nil)
        #expect(row.unpricedTokens == nil)
        #expect(row.input == 10)
    }

    @Test
    func `legacy analytics payload decodes without additive comparison and interval fields`() throws {
        let intervals = self.intervals(days: 7)
        let snapshot = self.build(
            current: [self.fragment(day: intervals.current.start, model: "model-a", input: 10, output: 0)],
            previous: [],
            intervals: intervals,
            legacyTotal: 10)
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "previousActiveModelCount")
        object.removeValue(forKey: "currentIsComplete")
        object.removeValue(forKey: "previousIsComplete")
        object.removeValue(forKey: "newlyActiveModelCount")
        object.removeValue(forKey: "previousSessionReferenceTotal")
        object.removeValue(forKey: "sessionReferenceComparison")
        object["rows"] = try (#require(object["rows"] as? [[String: Any]])).map { value in
            var row = value
            row.removeValue(forKey: "previousTotalTokens")
            row.removeValue(forKey: "previousCost")
            row.removeValue(forKey: "previousSessionReferences")
            row.removeValue(forKey: "associatedSessionIDs")
            return row
        }
        object["daily"] = try (#require(object["daily"] as? [[String: Any]])).map { value in
            var bucket = value
            bucket.removeValue(forKey: "interval")
            bucket.removeValue(forKey: "sessionReferenceIDs")
            return bucket
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CodexModelsAnalyticsSnapshot.self, from: legacyData)

        #expect(decoded.previousActiveModelCount == nil)
        #expect(decoded.currentIsComplete == nil)
        #expect(decoded.previousIsComplete == nil)
        #expect(decoded.newlyActiveModelCount == nil)
        #expect(decoded.rows[0].previousTotalTokens == nil)
        #expect(decoded.rows[0].associatedSessionIDs == nil)
        #expect(decoded.daily[0].interval == nil)
        #expect(decoded.daily[0].sessionReferenceIDs == decoded.daily[0].sessionIDs)
        #expect(decoded.totalTokens == 10)
    }

    @Test
    func `feature flag defaults on and supports rollback`() throws {
        let name = "CodexModelsAnalyticsTests.featureFlag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(CodexModelsRollout.isEnabled(defaults: defaults))
        defaults.set(false, forKey: CodexModelsRollout.featureFlagKey)
        #expect(!CodexModelsRollout.isEnabled(defaults: defaults))
    }

    private func build(
        current: [CodexModelsUsageFragment],
        previous: [CodexModelsUsageFragment],
        intervals: (current: DateInterval, previous: DateInterval),
        legacyTotal: Int64,
        currentIsComplete: Bool = true,
        previousIsComplete: Bool = true) -> CodexModelsAnalyticsSnapshot
    {
        CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: current, previous: previous),
            scopeID: nil,
            periods: CodexModelsAnalyticsPeriods(current: intervals.current, previous: intervals.previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: intervals.current.end, indexRevision: "fixture"),
            legacy: CodexModelsLegacyBaseline(
                totalTokens: legacyTotal,
                modelIDs: Array(Set(current.map(\.rawModelID)))),
            currentIsComplete: currentIsComplete,
            previousIsComplete: previousIsComplete))
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
        timestamp: Date? = nil,
        model: String,
        input: Int64,
        output: Int64,
        session: String = "session",
        costNanos: Int64? = 100_000_000) -> CodexModelsUsageFragment
    {
        CodexModelsUsageFragment(
            workspaceID: "workspace",
            sessionID: session,
            day: day,
            timestamp: timestamp,
            rawModelID: model,
            inputTokens: input,
            cachedInputTokens: min(3, input),
            outputTokens: output,
            costNanos: costNanos)
    }
}
