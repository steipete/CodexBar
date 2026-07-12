import Foundation
import Testing
@testable import CodexBarCore

/// Regression coverage for GitHub issue #2089:
/// "Automatic cost refreshes can silently serve a stale scan and pin it
/// for the full token-cost TTL" (v0.42.1, build 103).
///
/// Stock v0.42.1 zeroes the scanner's `refreshMinIntervalSeconds` only
/// when `forceRefresh == true`. The app's hourly timer, the first
/// post-launch fetch, and cost-scope/settings changes are all non-forced,
/// so they keep the 60-second debounce. When such a fetch lands inside
/// the 60-second window after any prior scan, the cost/Claude/Pi scanners
/// skip file inspection entirely and return the previous cached report;
/// `UsageStore` then stamps `lastTokenFetchAt` and pins that stale snapshot
/// for the full `tokenFetchTTL` (60 minutes).
///
/// The fix lives in `CostUsageFetcher.loadTokenSnapshot`: app-side callers
/// already rate-limit via `UsageStore.tokenFetchTTL`, so the scanner-side
/// debounce is redundant on this path and only ever manifests as silent
/// staleness. When the caller did not override `refreshMinIntervalSeconds`,
/// the fetcher now forces the debounce off. Callers that *want* the
/// debounce can still opt in by passing a non-default value.
struct Issue2089ReproTests { @Test
    func `non-forced codex refresh sees newly appended rows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 12)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": ["model": model],
        ]
        let firstTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 0,
                        "output_tokens": 10,
                    ],
                    "model": model,
                ],
            ],
        ]
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "repro-session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                cacheRoot: env.cacheRoot))
        #expect(first.last30DaysTokens == 110)

        let secondTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 0,
                        "output_tokens": 16,
                    ],
                    "model": model,
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                cacheRoot: env.cacheRoot))
        #expect(
            refreshed.last30DaysTokens == 176,
            "non-forced refresh must observe rows appended within the debounce window")
    }

    @Test
    func `non-forced claude refresh sees newly appended rows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 12)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "claude-sonnet-4.5"
        let first: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 80,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 30,
                ],
            ],
        ]
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([first]))

        let firstReport = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: CostUsageScanner.Options(
                claudeProjectsRoots: [env.claudeProjectsRoot],
                cacheRoot: env.cacheRoot))
        #expect(firstReport.last30DaysTokens == 110)

        let second: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 40,
                    "cache_read_input_tokens": 6,
                    "output_tokens": 30,
                ],
            ],
        ]
        let third: [String: Any] = [
            "type": "assistant",
            "timestamp": iso2,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 100,
                    "cache_read_input_tokens": 50,
                    "output_tokens": 60,
                ],
            ],
        ]
        try env.jsonl([first, second, third])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: CostUsageScanner.Options(
                claudeProjectsRoots: [env.claudeProjectsRoot],
                cacheRoot: env.cacheRoot))
        #expect(
            refreshed.last30DaysTokens == 696,
            "non-forced claude refresh must observe rows appended within the debounce window")
    }

    @Test
    func `explicit non-default debounce is preserved by fetcher`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 12)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "openai/gpt-5.2-codex"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": ["model": model],
        ]
        let firstTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 0,
                        "output_tokens": 10,
                    ],
                    "model": model,
                ],
            ],
        ]
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "optout-session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        var explicitOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        explicitOptions.refreshMinIntervalSeconds = 3600

        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: explicitOptions)

        let secondTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 0,
                        "output_tokens": 16,
                    ],
                    "model": model,
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: explicitOptions)
        #expect(
            refreshed.last30DaysTokens == 110,
            "fetcher must not override an explicit non-default debounce")
    }
}
