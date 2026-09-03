import Foundation
import Testing
@testable import CodexBarCore

struct PiProviderTests {
    @Test
    func `pi provider exposes an independent aggregate token snapshot`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let entries: [[String: Any]] = [
            [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 20, "output": 5, "totalTokens": 25],
                ],
            ],
            [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "model": "claude-sonnet-4-6",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 4, "output": 1, "totalTokens": 5],
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-02T10-00-00-000Z_aggregate.jsonl",
            contents: env.jsonl(entries))

        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: piOptions)

        #expect(snapshot.sessionTokens == 30)
        #expect(snapshot.last30DaysTokens == 30)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.costProvenance == .listPriceEstimate)

        let cached = PiSessionCostScanner.loadCachedDailyReport(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot)
        #expect(cached?.summary?.totalTokens == 30)
    }

    @Test
    func `pi provider descriptor is registered for token history`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .pi)

        #expect(descriptor.metadata.displayName == "Pi")
        #expect(descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.tokenCost.supportsTokenSnapshot)
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.cli.supportsCostCommand)
    }

    @Test
    func `pi provider does not establish history when a configured root is missing`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let missingRoot = env.root.appendingPathComponent("not-mounted")
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: missingRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(!snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `pi provider does not establish history when a configured root cannot be inspected`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let unreadableRoot = env.root.appendingPathComponent("not-a-session-directory")
        try Data("not a directory".utf8).write(to: unreadableRoot)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: unreadableRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(!snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `pi provider keeps the last report while a refresh root is unavailable`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 20, "output": 5, "totalTokens": 25],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-02T10-00-00-000Z_existing.jsonl",
            contents: env.jsonl([entry]))
        let initialOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let initial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: initialOptions)
        #expect(initial.sessionTokens == 25)
        #expect(initial.historyCoverageIsEstablished)

        let unavailableRoot = env.root.appendingPathComponent("temporarily-unavailable")
        try Data("not a directory".utf8).write(to: unavailableRoot)
        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day.addingTimeInterval(1),
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: unavailableRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(refreshed.sessionTokens == 25)
        #expect(!refreshed.historyCoverageIsEstablished)
    }

    @Test
    func `pi provider marks a session read failure incomplete and keeps cached usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 3)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 20, "output": 5, "totalTokens": 25],
            ],
        ]
        let fileURL = try env.writePiSessionFile(
            relativePath: "2026-04-03T10-00-00-000Z_read-failure.jsonl",
            contents: env.jsonl([entry]))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let initial = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options,
            checkCancellation: nil)
        #expect(initial.isComplete)
        #expect(initial.report.data.first?.totalTokens == 25)

        let removeFile: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let refreshed = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(removeFile) {
            try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: .codex,
                since: day,
                until: day.addingTimeInterval(1),
                now: day.addingTimeInterval(1),
                options: PiSessionCostScanner.Options(
                    piSessionsRoot: env.piSessionsRoot,
                    cacheRoot: env.cacheRoot,
                    refreshMinIntervalSeconds: 0,
                    forceRescan: true),
                checkCancellation: nil)
        }
        #expect(!refreshed.isComplete)
        #expect(refreshed.report.data.first?.totalTokens == 25)
    }

    @Test
    func `pi provider marks truncated records incomplete`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 4)
        let padding = String(repeating: "x", count: 16 * 1024 * 1024 + 1024)
        let oversized = "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"padding\":\"\(padding)\"}}\n"
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-04T10-00-00-000Z_truncated.jsonl",
            contents: oversized)
        let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0),
            checkCancellation: nil)

        #expect(!result.isComplete)
    }
}
