import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
struct AntigravityCLIStrategyLinuxTests {
    @Test
    func `cli HTTPS is unavailable without Linux localhost trust`() async throws {
        let binaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-antigravity-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryURL.path)
        defer { try? FileManager.default.removeItem(at: binaryURL) }

        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .cli,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["ANTIGRAVITY_CLI_PATH": binaryURL.path],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let isAvailable = await AntigravityCLIHTTPSFetchStrategy().isAvailable(context)

        #expect(!isAvailable)
    }

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }
}
#endif
