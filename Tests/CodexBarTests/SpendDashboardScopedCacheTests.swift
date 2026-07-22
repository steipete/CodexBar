import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SpendDashboardScopedCacheTests {
    @Test
    func `production cached dashboard loader reads a validated scoped cache`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 15)
        let model = "openai/gpt-5.4"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "dashboard-cached.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: day),
                    "payload": ["model": model],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 42,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))
        _ = try await CostUsageFetcher(cacheRoot: env.cacheRoot).loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: SpendDashboardSource.scanDays,
            includePiSessions: false)
        let account = CodexSpendScanRequest(
            id: "profile",
            displayName: "Codex profile",
            source: .profileHome(path: env.codexHomeRoot.path),
            homePath: env.codexHomeRoot.path,
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "profile-cache")
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: ["profile|profile-cache"]),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: day,
            force: false)
        let cacheRoot = env.cacheRoot

        let result = await SpendDashboardSource.loadCached(request, cacheRootResolver: { _ in cacheRoot })

        #expect(result.inputs.count == 1)
        #expect(result.inputs.first?.snapshot.sessionTokens == 42)
        #expect(result.inputs.first?.snapshot.projects.isEmpty == true)
        #expect(result.inputs.first?.snapshot.sessions.isEmpty == true)
    }
}
