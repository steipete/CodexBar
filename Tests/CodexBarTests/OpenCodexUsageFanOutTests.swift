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

    @Test func `snapshotsBySubscription keeps OAuth xai and openai tokens on their subscription rows`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_787_270_400)
        let entries = Self.xaiEntries(now: now) + [
            OpenCodexUsageEntry(
                requestID: "openai-1",
                timestamp: now,
                provider: "openai",
                model: "gpt-5.6-sol",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 30, outputTokens: 10, totalTokens: 40),
                totalTokens: 40),
        ]
        let oauthBackedProviderIDs = try Self.oauthBackedProviderIDs(authMode: "oauth")
        let pricing = CostUsageCustomPricing(
            entries: ["xai/grok-4.6": .init(input: 2, output: 6)],
            fingerprint: "xai-oauth-test")

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: now,
            historyDays: 7,
            calendar: calendar,
            oauthBackedProviderIDs: oauthBackedProviderIDs,
            customPricing: pricing)

        #expect(Set(snapshots.keys) == [.codex, .grok])
        #expect(snapshots[.grok]?.last30DaysTokens == 200)
        let grokCost = try #require(snapshots[.grok]?.last30DaysCostUSD)
        #expect(abs(grokCost - 0.00056) < 0.000000000001)
        #expect(snapshots[.codex]?.last30DaysTokens == 40)
    }

    @Test func `snapshotsBySubscription leaves API key xai entries off the Grok row`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_787_270_400)
        let oauthBackedProviderIDs = try Self.oauthBackedProviderIDs(authMode: "apiKey")

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: Self.xaiEntries(now: now),
            now: now,
            historyDays: 7,
            calendar: calendar,
            oauthBackedProviderIDs: oauthBackedProviderIDs)

        #expect(snapshots[.grok] == nil)
        #expect(snapshots.isEmpty)
    }

    @Test func `bare xai model prices from the injected xai catalog`() throws {
        let catalog = try Self.pricingCatalog()
        let snapshot = try Self.pricingSnapshot(
            provider: "xai",
            model: "grok-4.6",
            catalog: catalog)
        let cost = try #require(snapshot.daily.first?.costUSD)

        #expect(abs(cost - 0.0023) < 0.000000000001)
    }

    @Test func `bare openai model keeps its pre qualification catalog price`() throws {
        let catalog = try Self.pricingCatalog()
        let snapshot = try Self.pricingSnapshot(
            provider: "openai",
            model: "gpt-5.6-sol",
            catalog: catalog)
        let cost = try #require(snapshot.daily.first?.costUSD)
        let expected = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 1000,
            cachedInputTokens: 200,
            outputTokens: 100,
            modelsDevCatalog: catalog))

        #expect(abs(expected - 0.00125) < 0.000000000001)
        #expect(cost == expected)
    }

    @Test func `bare kimi model stays unpriced with an injected kimi catalog`() throws {
        let snapshot = try Self.pricingSnapshot(
            provider: "kimi",
            model: "k3[1m]",
            catalog: Self.pricingCatalog())

        #expect(snapshot.daily.first?.costUSD == nil)
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

    private static func pricingSnapshot(
        provider: String,
        model: String,
        catalog: ModelsDevCatalog) throws -> CostUsageTokenSnapshot
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_787_270_400)
        return OpenCodexUsageAggregator.snapshot(
            entries: [
                OpenCodexUsageEntry(
                    requestID: "pricing-\(provider)",
                    timestamp: now,
                    provider: provider,
                    model: model,
                    usageStatus: .reported,
                    usage: OpenCodexTokenUsage(
                        inputTokens: 1000,
                        outputTokens: 100,
                        cacheReadInputTokens: 200,
                        totalTokens: 1100),
                    totalTokens: 1100),
            ],
            now: now,
            historyDays: 7,
            calendar: calendar,
            modelsDevCatalog: catalog)
    }

    private static func xaiEntries(now: Date) -> [OpenCodexUsageEntry] {
        [
            OpenCodexUsageEntry(
                requestID: "xai-1",
                timestamp: now,
                provider: "xai",
                model: "grok-4.6",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 100, outputTokens: 20, totalTokens: 120),
                totalTokens: 120),
            OpenCodexUsageEntry(
                requestID: "xai-2",
                timestamp: now,
                provider: "xai",
                model: "xai/grok-4.6",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 60, outputTokens: 20, totalTokens: 80),
                totalTokens: 80),
        ]
    }

    private static func oauthBackedProviderIDs(authMode: String) throws -> Set<String> {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodexUsageFanOutTests-\(UUID().uuidString)", isDirectory: true)
        let openCodexHome = home.appendingPathComponent(".opencodex", isDirectory: true)
        try fileManager.createDirectory(at: openCodexHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try """
        { "providers": { "xai": { "authMode": "\(authMode)" } } }
        """.write(
            to: openCodexHome.appendingPathComponent("config.json", isDirectory: false),
            atomically: true,
            encoding: .utf8)

        return OpenCodexUsageLog.oauthBackedProviderIDs(
            environment: ["OPENCODEX_HOME": openCodexHome.path],
            homeDirectory: home)
    }

    private static func pricingCatalog() throws -> ModelsDevCatalog {
        let json = """
        {
          "xai": {
            "id": "xai",
            "models": {
              "grok-4.6": {
                "id": "grok-4.6",
                "cost": { "input": 2, "output": 6, "cache_read": 0.5 }
              }
            }
          },
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 1, "output": 4, "cache_read": 0.25 }
              }
            }
          },
          "kimi": {
            "id": "kimi",
            "models": {
              "k3[1m]": {
                "id": "k3[1m]",
                "cost": { "input": 9, "output": 19 }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }
}
