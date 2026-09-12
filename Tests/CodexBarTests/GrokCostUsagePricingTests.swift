import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct GrokCostUsagePricingTests: GrokLocalSessionScannerTestSupport {
    @Test
    func `a turn without recorded spend reports exact tokens and the public list price`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 12)
        let now = turnAt.addingTimeInterval(600)
        let usage = self.usage(
            input: 1000,
            output: 100,
            cachedRead: 200,
            cacheCreation: 50,
            reasoning: 20,
            modelCalls: 1,
            modelUsage: [
                "grok-4.6-build": self.modelUsage(
                    input: 1000,
                    output: 100,
                    cachedRead: 200,
                    cacheCreation: 50,
                    reasoning: 20,
                    modelCalls: 1),
            ])
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: now)

        let summary = try self.summarize(fixture: fixture, now: now)
        let day = try #require(summary.daily.first)
        let expectedCost = (750.0 * 2e-6) + (200.0 * 0.5e-6) + (50.0 * 2e-6) + (100.0 * 6e-6)

        #expect(day.inputTokens == 1000)
        #expect(day.cacheReadTokens == 200)
        #expect(day.cacheCreationTokens == 50)
        #expect(day.outputTokens == 100)
        #expect(day.reasoningTokens == 20)
        #expect(day.totalTokens == 1100)
        #expect(day.requestCount == 1)
        #expect(day.estimatedRequestCount == 1)
        #expect(abs((day.costUSD ?? 0) - expectedCost) < 0.000000000001)

        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))
        #expect(snapshot.sessionTokens == 1100)
        #expect(abs((snapshot.sessionCostUSD ?? 0) - expectedCost) < 0.000000000001)
        #expect(abs((snapshot.last30DaysCostUSD ?? 0) - expectedCost) < 0.000000000001)
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.daily.first?.estimatedRequestCount == 1)
        #expect(snapshot.daily.first?.coverageCounts.priced == 0)
        #expect(snapshot.daily.first?.coverageCounts.estimated == 1)
    }

    @Test
    func `model call averages select tiers while reported remainders stay exact`() throws {
        let turnAt = try self.localDate(day: 20, hour: 13)
        let standardFixture = try self.makeFixture()
        let longFixture = try self.makeFixture()
        defer {
            try? FileManager.default.removeItem(at: standardFixture.root)
            try? FileManager.default.removeItem(at: longFixture.root)
        }
        let standardUsage = self.usage(
            input: 300_001,
            output: 17,
            cachedRead: 13,
            cacheCreation: 7,
            reasoning: 5,
            modelCalls: 10,
            modelUsage: [
                "grok-4.6-build": self.modelUsage(
                    input: 300_001,
                    output: 17,
                    cachedRead: 13,
                    cacheCreation: 7,
                    reasoning: 5,
                    modelCalls: 10),
            ])
        let longUsage = self.usage(
            input: 300_001,
            output: 17,
            cachedRead: 13,
            cacheCreation: 7,
            reasoning: 5,
            modelCalls: 1,
            modelUsage: [
                "grok-4.6-build": self.modelUsage(
                    input: 300_001,
                    output: 17,
                    cachedRead: 13,
                    cacheCreation: 7,
                    reasoning: 5,
                    modelCalls: 1),
            ])
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: standardUsage)],
            to: standardFixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: longUsage)],
            to: longFixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let standard = try #require(self.summarize(
            fixture: standardFixture,
            now: turnAt.addingTimeInterval(120)).daily.first)
        let long = try #require(self.summarize(
            fixture: longFixture,
            now: turnAt.addingTimeInterval(120)).daily.first)

        #expect(standard.inputTokens == 300_001)
        #expect(long.inputTokens == 300_001)
        #expect(standard.outputTokens == 17)
        #expect(standard.cacheReadTokens == 13)
        #expect(standard.cacheCreationTokens == 7)
        #expect(standard.modelBreakdowns.first?.inputTokens == 300_001)
        #expect(abs((standard.costUSD ?? 0) - self.expectedStandardCost(
            input: 300_001,
            output: 17,
            cachedRead: 13,
            cacheCreation: 7)) < 0.000000000001)
        #expect(abs((long.costUSD ?? 0) - self.expectedLongContextCost(
            input: 300_001,
            output: 17,
            cachedRead: 13,
            cacheCreation: 7)) < 0.000000000001)
        #expect((long.costUSD ?? 0) > (standard.costUSD ?? 0))
    }

    @Test
    func `mean input just under threshold deliberately stays on standard pricing`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 13, minute: 30)
        let input = 5_441_612
        let output = 280
        let modelCalls = 28
        let usage = self.usage(
            input: input,
            output: output,
            modelCalls: modelCalls,
            modelUsage: [
                "grok-4.6-build": self.modelUsage(
                    input: input,
                    output: output,
                    modelCalls: modelCalls),
            ])
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let day = try #require(self.summarize(
            fixture: fixture,
            now: turnAt.addingTimeInterval(120)).daily.first)

        #expect(input / modelCalls == 194_343)
        #expect(abs((day.costUSD ?? 0) - self.expectedStandardCost(
            input: input,
            output: output,
            cachedRead: 0,
            cacheCreation: 0)) < 0.000000000001)
    }

    @Test
    func `two raw SKUs keep separate pricing and exact catalog identities`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 14)
        let usage = self.usage(
            input: 300,
            output: 30,
            modelCalls: 2,
            modelUsage: [
                "grok-4.6-build": self.modelUsage(input: 100, output: 10, modelCalls: 1),
                "grok-build-0.1": self.modelUsage(input: 200, output: 20, modelCalls: 1),
            ])
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let day = try #require(self.summarize(
            fixture: fixture,
            now: turnAt.addingTimeInterval(120)).daily.first)
        let breakdowns = Dictionary(uniqueKeysWithValues: day.modelBreakdowns.map { ($0.modelName, $0) })
        let normalizedCost = (100.0 * 2e-6) + (10.0 * 6e-6)
        let exactBuildCost = (200.0 * 10e-6) + (20.0 * 20e-6)

        #expect(Set(breakdowns.keys) == ["grok-4.6-build", "grok-build-0.1"])
        #expect(abs((breakdowns["grok-4.6-build"]?.costUSD ?? 0) - normalizedCost) < 0.000000000001)
        #expect(abs((breakdowns["grok-build-0.1"]?.costUSD ?? 0) - exactBuildCost) < 0.000000000001)
        #expect(abs((day.costUSD ?? 0) - normalizedCost - exactBuildCost) < 0.000000000001)
    }

    @Test
    func `missing model call split over threshold stays unpriced`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 18)
        let model = self.modelUsage(input: 300_000, output: 10, modelCalls: nil)
        let usage = self.usage(
            input: 300_000,
            output: 10,
            modelCalls: nil,
            modelUsage: ["grok-4.6-build": model])
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let day = try #require(self.summarize(
            fixture: fixture,
            now: turnAt.addingTimeInterval(120)).daily.first)

        #expect(day.totalTokens == 300_010)
        #expect(day.requestCount == 1)
        #expect(day.costUSD == nil)
        #expect(day.unpricedRequestCount == 1)
        #expect(day.modelBreakdowns.first?.costUSD == nil)
    }

    @Test
    func `production nil catalog pricing reads only the injected models dev cache`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let turnAt = try self.localDate(day: 20, hour: 18, minute: 50)
        let cacheRoot = fixture.root.appendingPathComponent("fixture-cache", isDirectory: true)
        #expect(try ModelsDevCache.save(catalog: Self.catalog(), fetchedAt: turnAt, cacheRoot: cacheRoot))
        try self.writeUpdates(
            [self.turn(timestamp: turnAt, usage: self.singleModelUsage(input: 1000, output: 100))],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: turnAt.addingTimeInterval(60))

        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 7,
            now: turnAt.addingTimeInterval(120),
            modelsDevCacheRoot: cacheRoot)
        let day = try #require(summary.daily.first)

        #expect(abs((day.costUSD ?? 0) - self.expectedStandardCost(
            input: 1000,
            output: 100,
            cachedRead: 0,
            cacheCreation: 0)) < 0.000000000001)
    }

    @MainActor
    @Test
    func `retained Grok history narrows daily rows and recomputes window totals`() throws {
        let scannedAt = try self.localDate(day: 20, hour: 19)
        let calendar = Calendar.current
        let recentAt = try #require(calendar.date(byAdding: .day, value: -10, to: scannedAt))
        let olderAt = try #require(calendar.date(byAdding: .day, value: -40, to: scannedAt))
        let recentDay = try #require(GrokLocalSessionScanner.dayKey(for: recentAt, calendar: calendar))
        let olderDay = try #require(GrokLocalSessionScanner.dayKey(for: olderAt, calendar: calendar))
        let summary = GrokLocalSessionSummary(
            sessionCount: 2,
            totalTokens: 150,
            lastSessionAt: recentAt,
            primaryModel: "grok-4.6-build",
            models: ["grok-4.6-build"],
            daily: [
                GrokLocalDailyBucket(
                    date: olderDay,
                    totalTokens: 100,
                    sessionCount: 1,
                    requestCount: 1,
                    costUSD: 1,
                    models: ["grok-4.6-build"]),
                GrokLocalDailyBucket(
                    date: recentDay,
                    totalTokens: 50,
                    sessionCount: 1,
                    requestCount: 1,
                    costUSD: 0.5,
                    models: ["grok-4.6-build"]),
            ],
            scannedAt: scannedAt)
        let full = try #require(summary.toCostUsageTokenSnapshot(
            historyDays: GrokLocalSessionScanner.maximumLookbackDays))

        let narrowed = full.narrowed(toHistoryDays: 30, calendar: calendar)
        let maximum = full.narrowed(
            toHistoryDays: GrokLocalSessionScanner.maximumLookbackDays,
            calendar: calendar)

        #expect(narrowed.historyDays == 30)
        #expect(narrowed.last30DaysTokens == 50)
        #expect(narrowed.last30DaysCostUSD == 0.5)
        #expect(narrowed.last30DaysRequests == 1)
        #expect(narrowed.daily.map(\.date) == [recentDay])
        #expect(maximum.historyDays == 365)
        #expect(maximum.last30DaysTokens == 150)
        #expect(maximum.last30DaysCostUSD == 1.5)
        #expect(maximum.daily.map(\.date) == [olderDay, recentDay])
        // A window that kept a priced row keeps its disclosure; one that kept none claims nothing rather
        // than inheriting the snapshot's.
        #expect(narrowed.costProvenance == full.costProvenance)
        #expect(full.narrowed(toHistoryDays: 1, calendar: calendar).costProvenance == .unknown)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: testSettingsStore(suiteName: "GrokLocalSessionScannerTests-narrowed"),
            startupBehavior: .testing,
            environmentBase: [:])
        let providerSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: full,
            updatedAt: scannedAt,
            identity: nil)
        let projected30 = store.tokenSnapshot(
            fromProviderSnapshot: providerSnapshot,
            provider: .grok,
            historyDays: 30)
        let projected365 = store.tokenSnapshot(
            fromProviderSnapshot: providerSnapshot,
            provider: .grok,
            historyDays: 365)

        #expect(projected30?.historyDays == 30)
        #expect(projected30?.last30DaysTokens == 50)
        #expect(projected30?.daily.map(\.date) == [recentDay])
        #expect(projected365?.historyDays == 365)
        #expect(projected365?.last30DaysTokens == 150)
        #expect(projected365?.daily.map(\.date) == [olderDay, recentDay])
    }
}

extension GrokCostUsagePricingTests {
    @Test
    func `xai catalog changes use a separate fingerprint from Codex caches`() throws {
        let first = try Self.modelsDevArtifact("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 5, "output": 30 }
              }
            }
          },
          "xai": {
            "id": "xai",
            "models": {
              "grok-4.6": {
                "id": "grok-4.6",
                "cost": { "input": 2, "output": 6 }
              }
            }
          }
        }
        """)
        let xaiPriceChanged = try Self.modelsDevArtifact("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 5, "output": 30 }
              }
            }
          },
          "xai": {
            "id": "xai",
            "models": {
              "grok-4.6": {
                "id": "grok-4.6",
                "cost": { "input": 3, "output": 7 }
              }
            }
          }
        }
        """)

        let firstCodexKey = CostUsagePricingKey.codex(modelsDevArtifact: first, formulaVersion: 1)
        let changedCodexKey = CostUsagePricingKey.codex(modelsDevArtifact: xaiPriceChanged, formulaVersion: 1)
        let firstXAIKey = CostUsagePricingKey.codex(
            modelsDevArtifact: first,
            formulaVersion: 1,
            modelsDevProviderIDs: CostUsagePricing.xaiModelsDevProviderIDs)
        let changedXAIKey = CostUsagePricingKey.codex(
            modelsDevArtifact: xaiPriceChanged,
            formulaVersion: 1,
            modelsDevProviderIDs: CostUsagePricing.xaiModelsDevProviderIDs)

        #expect(firstCodexKey == changedCodexKey)
        #expect(firstXAIKey != changedXAIKey)
    }

    private static func modelsDevArtifact(_ json: String) throws -> ModelsDevCacheArtifact {
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        return ModelsDevCacheArtifact(
            version: ModelsDevCache.artifactVersion,
            fetchedAt: Date(timeIntervalSince1970: 0),
            catalog: catalog)
    }
}
