import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenCodexUsageFanOutTests {
    @Test func `snapshotsBySubscription routes openai spend into codex`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "codex-1",
                timestamp: now,
                provider: "openai",
                model: "openai/gpt-5.2",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
                totalTokens: 150),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.keys.contains(.codex))
        #expect(snapshots[.codex]?.last30DaysTokens == 150)
    }

    @Test func `snapshotsBySubscription routes opencode go spend into open code go`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "ocgo-1",
                timestamp: now,
                provider: "opencode-go",
                model: "opencode-go/gpt-5.2",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 80, outputTokens: 20, totalTokens: 100),
                totalTokens: 100),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.keys.contains(.opencodego))
        #expect(snapshots[.opencodego]?.last30DaysTokens == 100)
    }

    @Test func `snapshotsBySubscription skips token only providers`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "free-1",
                timestamp: now,
                provider: "opencode-free",
                model: "opencode-free/gpt-5.2",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 40, outputTokens: 10, totalTokens: 50),
                totalTokens: 50),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.isEmpty)
    }

    @Test func `snapshotsBySubscription prefers a routed model prefix over provider`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entries = [
            OpenCodexUsageEntry(
                requestID: "mismatch-1",
                timestamp: now,
                provider: "openai",
                model: "opencode-go/deepseek-v4-flash",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 40, outputTokens: 10, totalTokens: 50),
                totalTokens: 50),
        ]

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar)

        #expect(snapshots.keys.contains(.opencodego))
        #expect(snapshots[.codex] == nil)
    }

    @Test func `preferredMergeIndex returns nil for codex when multiple codex accounts exist`() {
        let dummySnapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 7,
            daily: [],
            updatedAt: Date())
        let singleCodex = [
            SpendDashboardModel.ProviderInput(
                id: "codex:acct-1",
                provider: .codex,
                displayName: "Work Account",
                snapshot: dummySnapshot),
        ]
        #expect(SpendDashboardSource.preferredMergeIndex(for: .codex, in: singleCodex) == 0)

        let multipleCodex = [
            SpendDashboardModel.ProviderInput(
                id: "codex:acct-1",
                provider: .codex,
                displayName: "Work Account",
                snapshot: dummySnapshot),
            SpendDashboardModel.ProviderInput(
                id: "codex:acct-2",
                provider: .codex,
                displayName: "Personal Account",
                snapshot: dummySnapshot),
        ]
        #expect(SpendDashboardSource.preferredMergeIndex(for: .codex, in: multipleCodex) == nil)
    }

    @Test func `mergingOpenCodexInputs drops opencodex when hidden in hiddenSourceIDs`() {
        let dummySnapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 7,
            daily: [],
            updatedAt: Date())
        let dummy = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: dummySnapshot)
        let config = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [],
            openCodexUsageLogsEnabled: true,
            hiddenSourceIDs: [SpendDashboardModel.openCodexSourceID])
        let request = SpendDashboardLoadRequest(
            configuration: config,
            capturedInputs: [dummy],
            unavailableSourceIDs: [],
            confirmedEmptySourceIDs: [],
            codexRequests: [],
            now: Date(),
            force: false)

        let result = SpendDashboardSource.mergingOpenCodexInputs([dummy], request: request)
        #expect(!result.contains(where: { $0.id == SpendDashboardModel.openCodexSourceID }))
    }

    @Test
    func `snapshot matches a naive per-entry reference across DST and overlays`() throws {
        let calendar = try Self.losAngelesCalendar()
        let now = try Self.date(calendar, DateComponents(year: 2026, month: 11, day: 2, hour: 12, minute: 0))
        let customPricing = CostUsageCustomPricing.parse(Data("""
        {
          "openai/gpt-5.4": { "input": 1.5, "output": 6, "cacheRead": 0.15, "cacheWrite": 1.875 }
        }
        """.utf8))
        let firstFallBack = try Self.date(calendar, DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30))
        let entries = try [
            OpenCodexUsageEntry(
                requestID: "dup",
                timestamp: Self.date(calendar, DateComponents(year: 2026, month: 11, day: 1, hour: 10, minute: 0)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .reported,
                conversationID: "chat-dup",
                usage: OpenCodexTokenUsage(inputTokens: 1, outputTokens: 1, totalTokens: 2),
                totalTokens: 2),
            OpenCodexUsageEntry(
                requestID: "dup",
                timestamp: Self.date(calendar, DateComponents(year: 2026, month: 11, day: 1, hour: 10, minute: 5)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .reported,
                conversationID: "chat-dup",
                usage: OpenCodexTokenUsage(
                    inputTokens: 80,
                    outputTokens: 20,
                    cacheReadInputTokens: 10,
                    cacheCreationInputTokens: 5,
                    totalTokens: 100),
                totalTokens: 100),
            OpenCodexUsageEntry(
                requestID: "spring",
                timestamp: Self.date(calendar, DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .reported,
                conversationID: "chat-dst",
                usage: OpenCodexTokenUsage(inputTokens: 40, outputTokens: 10, totalTokens: 50),
                totalTokens: 50),
            OpenCodexUsageEntry(
                requestID: "spring-after",
                timestamp: Self.date(calendar, DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 0)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .estimated,
                conversationID: "chat-dst",
                usage: OpenCodexTokenUsage(inputTokens: 20, outputTokens: 4, totalTokens: 24),
                totalTokens: 24),
            OpenCodexUsageEntry(
                requestID: "fallback-first",
                timestamp: firstFallBack,
                provider: "opencode-go",
                model: "opencode-go/gpt-5.2",
                usageStatus: .reported,
                conversationID: "chat-fallback",
                usage: OpenCodexTokenUsage(inputTokens: 12, outputTokens: 3, totalTokens: 15),
                totalTokens: 15),
            OpenCodexUsageEntry(
                requestID: "fallback-second",
                timestamp: firstFallBack.addingTimeInterval(3600),
                provider: "opencode-go",
                model: "opencode-go/gpt-5.2",
                usageStatus: .reported,
                conversationID: "chat-fallback",
                usage: OpenCodexTokenUsage(inputTokens: 8, outputTokens: 2, totalTokens: 10),
                totalTokens: 10),
            OpenCodexUsageEntry(
                requestID: "unreported",
                timestamp: Self.date(calendar, DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 0)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .unreported,
                conversationID: "chat-today"),
            OpenCodexUsageEntry(
                requestID: "unsupported",
                timestamp: Self.date(calendar, DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 15)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .unsupported,
                conversationID: "chat-today",
                usage: OpenCodexTokenUsage(inputTokens: 4, outputTokens: 1, totalTokens: 5),
                totalTokens: 5),
            OpenCodexUsageEntry(
                requestID: "unknown-estimated",
                timestamp: Self.date(calendar, DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 30)),
                provider: "openai",
                model: "not-a-priced-model-xyz",
                usageStatus: .estimated,
                conversationID: "chat-today",
                usage: OpenCodexTokenUsage(inputTokens: 6, outputTokens: 1, totalTokens: 7),
                totalTokens: 7),
            OpenCodexUsageEntry(
                requestID: "outside-window",
                timestamp: Self.date(calendar, DateComponents(year: 2024, month: 1, day: 1, hour: 12, minute: 0)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 999, outputTokens: 1, totalTokens: 1000),
                totalTokens: 1000),
            OpenCodexUsageEntry(
                requestID: "catalog-priced",
                timestamp: now,
                provider: "openai",
                model: "gpt-5.2",
                usageStatus: .reported,
                conversationID: "chat-catalog",
                usage: OpenCodexTokenUsage(inputTokens: 1000, outputTokens: 1000, totalTokens: 2000),
                totalTokens: 2000),
        ]

        let root = try Self.modelsDevCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureCatalog = Self.fixturePricingCatalog()
        #expect(ModelsDevCache.save(catalog: fixtureCatalog, fetchedAt: now, cacheRoot: root))
        let loadedCatalog = try #require(ModelsDevCache.load(cacheRoot: root).artifact?.catalog)

        let snapshot = OpenCodexUsageAggregator.snapshot(
            entries: entries,
            now: now,
            historyDays: 365,
            calendar: calendar,
            customPricing: customPricing,
            modelsDevCatalog: loadedCatalog)
        let reference = OpenCodexUsageSnapshotReference.snapshot(
            entries: entries,
            now: now,
            historyDays: 365,
            calendar: calendar,
            customPricing: customPricing,
            modelsDevCacheRoot: root)

        #expect(snapshot == reference)
        #expect(snapshot.daily.count >= 3)
        #expect(snapshot.hourly.count >= 5)
        #expect(snapshot.sessions.contains { $0.sessionID == "chat-dup" && $0.requestCount == 1 })

        let catalogPriced = try #require(
            snapshot.daily.flatMap { $0.modelBreakdowns ?? [] }.first { $0.modelName == "gpt-5.2" })
        let catalogCost = try #require(catalogPriced.costUSD)
        let bundledCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2",
            inputTokens: 1000,
            cachedInputTokens: 0,
            outputTokens: 1000,
            cacheWriteInputTokens: 0,
            pricingDate: now,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]),
            customPricing: .empty)
        #expect(catalogCost != bundledCost)
    }

    @Test
    func `snapshot resolves the models.dev catalog once for many entries`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let entryCount = 60
        let entries = (0..<entryCount).map { index in
            OpenCodexUsageEntry(
                requestID: "req-\(index)",
                timestamp: now.addingTimeInterval(TimeInterval(-index * 30)),
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 10 + index, outputTokens: 2, totalTokens: 12 + index),
                totalTokens: 12 + index)
        }
        let unresolvedRecorder = ModelsDevCache.MetadataReadRecorder()
        let snapshot = ModelsDevCache.withMetadataReadRecorderForTesting(unresolvedRecorder) {
            OpenCodexUsageAggregator.snapshot(
                entries: entries,
                now: now,
                historyDays: 7,
                calendar: calendar)
        }

        #expect(!snapshot.daily.isEmpty)
        #expect(unresolvedRecorder.snapshot() == 1)

        let injectedRecorder = ModelsDevCache.MetadataReadRecorder()
        let injected = ModelsDevCache.withMetadataReadRecorderForTesting(injectedRecorder) {
            OpenCodexUsageAggregator.snapshot(
                entries: entries,
                now: now,
                historyDays: 7,
                calendar: calendar,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        }
        #expect(!injected.daily.isEmpty)
        #expect(injectedRecorder.snapshot() == 0)
    }

    @Test
    func `day and hour memos follow calendar intervals across DST and hour boundaries`() throws {
        let calendar = try Self.losAngelesCalendar()
        let now = try Self.date(calendar, DateComponents(year: 2026, month: 11, day: 2, hour: 12, minute: 0))
        let springBefore = try Self.date(calendar, DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 59))
        let springAfter = try Self.date(calendar, DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 0))
        let hourBefore = try Self.date(
            calendar,
            DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 59, second: 59))
        let hourStart = try Self.date(calendar, DateComponents(year: 2026, month: 11, day: 2, hour: 10, minute: 0))
        let midnight = try Self.date(calendar, DateComponents(year: 2026, month: 11, day: 2, hour: 0, minute: 0))
        let beforeMidnight = try Self.date(
            calendar,
            DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 59, second: 59))
        let firstFallBack = try Self.date(calendar, DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30))
        let secondFallBack = firstFallBack.addingTimeInterval(3600)
        let samples: [(id: String, timestamp: Date, tokens: Int)] = [
            ("spring-before", springBefore, 11),
            ("spring-after", springAfter, 13),
            ("hour-before", hourBefore, 17),
            ("hour-start", hourStart, 19),
            ("midnight", midnight, 23),
            ("before-midnight", beforeMidnight, 29),
            ("fallback-first", firstFallBack, 31),
            ("fallback-second", secondFallBack, 37),
        ]
        try Self.assertDayAndHourMemos(calendar: calendar, now: now, samples: samples)
        #expect(CostUsageLocalDay.key(from: midnight, calendar: calendar)
            != CostUsageLocalDay.key(from: beforeMidnight, calendar: calendar))
        #expect(
            calendar.dateInterval(of: .hour, for: firstFallBack)?.start
                != calendar.dateInterval(of: .hour, for: secondFallBack)?.start)

        let santiago = try Self.santiagoCalendar()
        let santiagoNow = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 9, day: 7, hour: 12, minute: 0))
        let april4Start = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 4, day: 4, hour: 0, minute: 0))
        let firstRepeatedHour = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 4, day: 4, hour: 23, minute: 30))
        let secondRepeatedHour = firstRepeatedHour.addingTimeInterval(3600)
        let april5Start = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 4, day: 5, hour: 0, minute: 0))
        let beforeSpring = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 9, day: 5, hour: 23, minute: 59, second: 59))
        let sept6Start = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 9, day: 6, hour: 1, minute: 0))
        let afterSpring = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 9, day: 6, hour: 2, minute: 0))
        let sept7Start = try Self.date(
            santiago,
            DateComponents(year: 2026, month: 9, day: 7, hour: 0, minute: 0))
        try Self.assertDayAndHourMemos(
            calendar: santiago,
            now: santiagoNow,
            samples: [
                ("santiago-april4-start", april4Start, 101),
                ("santiago-fallback-first", firstRepeatedHour, 103),
                ("santiago-fallback-second", secondRepeatedHour, 107),
                ("santiago-april5-start", april5Start, 109),
                ("santiago-before-spring", beforeSpring, 113),
                ("santiago-sept6-start", sept6Start, 127),
                ("santiago-after-spring", afterSpring, 131),
                ("santiago-sept7-start", sept7Start, 137),
            ])
        #expect(
            santiago.dateInterval(of: .hour, for: firstRepeatedHour)?.start
                != santiago.dateInterval(of: .hour, for: secondRepeatedHour)?.start)
        #expect(
            CostUsageLocalDay.key(from: april4Start, calendar: santiago)
                != CostUsageLocalDay.key(from: april5Start, calendar: santiago))
        #expect(
            CostUsageLocalDay.key(from: beforeSpring, calendar: santiago)
                != CostUsageLocalDay.key(from: sept6Start, calendar: santiago))
    }

    private static func losAngelesCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    private static func santiagoCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        return calendar
    }

    private static func date(_ calendar: Calendar, _ components: DateComponents) throws -> Date {
        try #require(calendar.date(from: components))
    }

    private static func assertDayAndHourMemos(
        calendar: Calendar,
        now: Date,
        samples: [(id: String, timestamp: Date, tokens: Int)]) throws
    {
        let entries = samples.map { sample in
            OpenCodexUsageEntry(
                requestID: sample.id,
                timestamp: sample.timestamp,
                provider: "openai",
                model: "gpt-5.4",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(
                    inputTokens: sample.tokens,
                    outputTokens: 0,
                    totalTokens: sample.tokens),
                totalTokens: sample.tokens)
        }
        let snapshot = OpenCodexUsageAggregator.snapshot(
            entries: entries,
            now: now,
            historyDays: 365,
            calendar: calendar)
        for sample in samples {
            let expectedDay = CostUsageLocalDay.key(from: sample.timestamp, calendar: calendar)
            let expectedHour = calendar.dateInterval(of: .hour, for: sample.timestamp)?.start
                ?? sample.timestamp
            let day = try #require(snapshot.daily.first { $0.date == expectedDay })
            let hour = try #require(snapshot.hourly.first { $0.hour == expectedHour })
            #expect(day.totalTokens ?? 0 >= sample.tokens)
            #expect(hour.totalTokens == sample.tokens)
            #expect(hour.hour == expectedHour)
        }
    }

    private static func modelsDevCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-opencodex-modelsdev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func fixturePricingCatalog() -> ModelsDevCatalog {
        ModelsDevCatalog(providers: [
            "openai": ModelsDevProvider(
                id: "openai",
                name: "OpenAI",
                models: [
                    "gpt-5.2": ModelsDevModel(
                        id: "gpt-5.2",
                        name: nil,
                        cost: ModelsDevCost(input: 99, output: 199),
                        limit: nil),
                    "gpt-5.4": ModelsDevModel(
                        id: "gpt-5.4",
                        name: nil,
                        cost: ModelsDevCost(input: 88, output: 188),
                        limit: nil),
                ]),
            "opencode-go": ModelsDevProvider(
                id: "opencode-go",
                name: nil,
                models: [
                    "gpt-5.2": ModelsDevModel(
                        id: "gpt-5.2",
                        name: nil,
                        cost: ModelsDevCost(input: 50, output: 80),
                        limit: nil),
                ]),
        ])
    }
}

private enum OpenCodexUsageSnapshotReference {
    static func snapshot(
        entries: [OpenCodexUsageEntry],
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        customPricing: CostUsageCustomPricing,
        modelsDevCacheRoot: URL? = nil) -> CostUsageTokenSnapshot
    {
        let days = max(1, min(365, historyDays))
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var unique: [String: OpenCodexUsageEntry] = [:]
        for entry in entries {
            unique[entry.requestID] = entry
        }
        let windowed = unique.values.filter { $0.timestamp >= windowStart && $0.timestamp <= now }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.requestID < rhs.requestID
            }

        var daysByKey: [String: OpenCodexUsageAggregator.DayAccumulator] = [:]
        var sessions: [String: OpenCodexUsageAggregator.SessionAccumulator] = [:]
        var hoursByStart: [Date: OpenCodexUsageAggregator.HourAccumulator] = [:]
        for entry in windowed {
            let cost = Self.listPriceUSD(
                entry: entry,
                customPricing: customPricing,
                modelsDevCacheRoot: modelsDevCacheRoot)
            let dayKey = CostUsageLocalDay.key(from: entry.timestamp, calendar: calendar)
            var day = daysByKey[dayKey] ?? OpenCodexUsageAggregator.DayAccumulator()
            Self.merge(entry, cost: cost, into: &day)
            daysByKey[dayKey] = day

            let sessionID = entry.conversationID ?? entry.requestID
            var session = sessions[sessionID] ?? OpenCodexUsageAggregator.SessionAccumulator()
            session.lastActivity = max(session.lastActivity, entry.timestamp)
            session.requests += 1
            Self.merge(entry, cost: cost, into: &session)
            sessions[sessionID] = session

            let hour = calendar.dateInterval(of: .hour, for: entry.timestamp)?.start ?? entry.timestamp
            var hourBucket = hoursByStart[hour] ?? OpenCodexUsageAggregator.HourAccumulator()
            Self.merge(entry, cost: cost, into: &hourBucket)
            hoursByStart[hour] = hourBucket
        }

        let daily = daysByKey.keys.sorted().compactMap { key -> CostUsageDailyReport.Entry? in
            guard let day = daysByKey[key] else { return nil }
            return Self.entry(dayKey: key, day: day)
        }
        let sessionRows = sessions.keys.sorted().compactMap { key -> CostUsageSessionBreakdown? in
            guard let session = sessions[key] else { return nil }
            return CostUsageSessionBreakdown(
                sessionID: key,
                lastActivity: session.lastActivity,
                inputTokens: session.input,
                cachedInputTokens: session.cacheRead,
                outputTokens: session.output,
                reasoningTokens: session.reasoning,
                totalTokens: session.tokens,
                requestCount: session.requests,
                costUSD: session.cost,
                modelBreakdowns: Self.modelBreakdowns(session.models))
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID < rhs.sessionID
        }
        let hourly = hoursByStart.keys.sorted().map { hour in
            let bucket = hoursByStart[hour] ?? OpenCodexUsageAggregator.HourAccumulator()
            return CostUsageHourlyEntry(
                hour: hour,
                totalTokens: bucket.sawTokens ? bucket.tokens : nil,
                costUSD: bucket.sawCost ? bucket.cost : nil)
        }
        let todayEntry = CostUsageTokenSnapshot.entry(
            in: daily,
            forLocalDayContaining: now,
            calendar: calendar)
        let windowSummary = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: days,
            daily: daily,
            sessions: Array(sessionRows.prefix(64)),
            updatedAt: now)
            .summary(forLastDays: min(30, days), calendar: calendar)
        return CostUsageTokenSnapshot(
            sessionTokens: todayEntry?.totalTokens ?? (daily.isEmpty ? nil : 0),
            sessionCostUSD: todayEntry?.costUSD ?? (daily.isEmpty ? nil : 0),
            sessionRequests: todayEntry?.requestCount ?? (daily.isEmpty ? nil : 0),
            last30DaysTokens: windowSummary.totalTokens,
            last30DaysCostUSD: windowSummary.totalCostUSD,
            last30DaysRequests: windowSummary.totalRequests,
            historyDays: days,
            historyLabel: "OpenCodex usage.jsonl",
            costProvenance: .listPriceEstimate,
            daily: daily,
            sessions: Array(sessionRows.prefix(64)),
            hourly: hourly,
            updatedAt: now)
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into day: inout OpenCodexUsageAggregator.DayAccumulator)
    {
        let usage = entry.usage
        if let input = usage?.inputTokens {
            day.input += input
            day.sawInput = true
        }
        if let output = usage?.outputTokens {
            day.output += output
            day.sawOutput = true
        }
        if let cacheRead = usage?.cacheReadTokens {
            day.cacheRead += cacheRead
            day.sawCacheRead = true
        }
        if let cacheCreation = usage?.cacheCreationInputTokens {
            day.cacheCreation += cacheCreation
            day.sawCacheCreation = true
        }
        if let reasoning = usage?.reasoningOutputTokens {
            day.reasoning += reasoning
            day.sawReasoning = true
        }
        if let tokens = entry.resolvedTotalTokens {
            day.tokens += tokens
            day.sawTokens = true
        }
        day.priced += entry.usageStatus == .reported ? 1 : 0
        day.estimated += entry.usageStatus == .estimated ? 1 : 0
        day.unmetered += entry.usageStatus == .unsupported ? 1 : 0
        day.unpriced += entry.usageStatus == .unreported ? 1 : 0
        if let cost {
            day.cost += cost
            day.sawCost = true
        } else if entry.usageStatus == .reported {
            day.unpriced += 1
            if day.priced > 0 {
                day.priced -= 1
            }
        } else if entry.usageStatus == .estimated {
            day.unpriced += 1
            if day.estimated > 0 {
                day.estimated -= 1
            }
        }
        var model = day.models[entry.model] ?? OpenCodexUsageAggregator.ModelAccumulator()
        Self.merge(entry, cost: cost, into: &model)
        day.models[entry.model] = model
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into session: inout OpenCodexUsageAggregator.SessionAccumulator)
    {
        session.input = self.add(session.input, entry.usage?.inputTokens)
        session.output = self.add(session.output, entry.usage?.outputTokens)
        session.cacheRead = self.add(session.cacheRead, entry.usage?.cacheReadTokens)
        session.reasoning = self.add(session.reasoning, entry.usage?.reasoningOutputTokens)
        session.tokens = self.add(session.tokens, entry.resolvedTotalTokens)
        session.cost = self.add(session.cost, cost)
        var model = session.models[entry.model] ?? OpenCodexUsageAggregator.ModelAccumulator()
        Self.merge(entry, cost: cost, into: &model)
        session.models[entry.model] = model
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into hour: inout OpenCodexUsageAggregator.HourAccumulator)
    {
        if let tokens = entry.resolvedTotalTokens {
            hour.tokens += tokens
            hour.sawTokens = true
        }
        if let cost {
            hour.cost += cost
            hour.sawCost = true
        }
    }

    private static func merge(
        _ entry: OpenCodexUsageEntry,
        cost: Double?,
        into model: inout OpenCodexUsageAggregator.ModelAccumulator)
    {
        model.input = self.add(model.input, entry.usage?.inputTokens)
        model.output = self.add(model.output, entry.usage?.outputTokens)
        model.cacheRead = self.add(model.cacheRead, entry.usage?.cacheReadTokens)
        model.cacheCreation = self.add(model.cacheCreation, entry.usage?.cacheCreationInputTokens)
        model.reasoning = self.add(model.reasoning, entry.usage?.reasoningOutputTokens)
        if let tokens = entry.resolvedTotalTokens {
            model.tokens += tokens
            model.sawTokens = true
        }
        if let cost {
            model.cost += cost
            model.sawCost = true
        }
    }

    private static func entry(
        dayKey: String,
        day: OpenCodexUsageAggregator.DayAccumulator) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: dayKey,
            inputTokens: day.sawInput ? day.input : nil,
            outputTokens: day.sawOutput ? day.output : nil,
            cacheReadTokens: day.sawCacheRead ? day.cacheRead : nil,
            cacheCreationTokens: day.sawCacheCreation ? day.cacheCreation : nil,
            reasoningTokens: day.sawReasoning ? day.reasoning : nil,
            totalTokens: day.sawTokens ? day.tokens : nil,
            requestCount: day.priced + day.unpriced + day.unmetered + day.estimated,
            costUSD: day.sawCost ? day.cost : nil,
            modelsUsed: day.models.keys.sorted(),
            modelBreakdowns: self.modelBreakdowns(day.models),
            unpricedRequestCount: day.unpriced,
            unmeteredRequestCount: day.unmetered,
            estimatedRequestCount: day.estimated)
    }

    private static func modelBreakdowns(
        _ models: [String: OpenCodexUsageAggregator.ModelAccumulator]) -> [CostUsageDailyReport.ModelBreakdown]
    {
        models.keys.sorted().map { name in
            let model = models[name] ?? OpenCodexUsageAggregator.ModelAccumulator()
            return CostUsageDailyReport.ModelBreakdown(
                modelName: name,
                costUSD: model.sawCost ? model.cost : nil,
                totalTokens: model.sawTokens ? model.tokens : nil,
                inputTokens: model.input,
                outputTokens: model.output,
                cacheReadTokens: model.cacheRead,
                cacheCreationTokens: model.cacheCreation,
                reasoningTokens: model.reasoning)
        }
    }

    private static func listPriceUSD(
        entry: OpenCodexUsageEntry,
        customPricing: CostUsageCustomPricing,
        modelsDevCacheRoot: URL?) -> Double?
    {
        guard entry.usageStatus == .reported || entry.usageStatus == .estimated else { return nil }
        let usage = entry.usage
        let hasTokenData = entry.resolvedTotalTokens != nil
            || usage?.inputTokens != nil
            || usage?.outputTokens != nil
            || usage?.cacheReadTokens != nil
            || usage?.cacheCreationInputTokens != nil
        guard hasTokenData else { return nil }
        let input = usage?.inputTokens ?? 0
        let output = usage?.outputTokens ?? 0
        let cacheRead = usage?.cacheReadTokens ?? 0
        let cacheWrite = usage?.cacheCreationInputTokens ?? 0
        if let overlay = customPricing.costUSD(
            providerID: entry.provider,
            model: entry.model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite)
        {
            return overlay
        }
        return CostUsagePricing.codexCostUSD(
            model: entry.model,
            inputTokens: input,
            cachedInputTokens: cacheRead,
            outputTokens: output,
            cacheWriteInputTokens: cacheWrite,
            pricingDate: entry.timestamp,
            modelsDevCacheRoot: modelsDevCacheRoot)
    }

    private static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (left?, right?): left + right
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private static func add(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): left + right
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }
}
