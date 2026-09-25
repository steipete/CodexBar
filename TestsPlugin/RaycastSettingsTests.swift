import Foundation
import Testing
@testable import CodexBarCore

struct RaycastSettingsTests {
    @Test
    func `descriptor uses Chrome cookies and the shared script strategy`() async throws {
        let descriptor = RaycastProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(descriptor.metadata.usesDetailBackedWindow)
        #expect(descriptor.credentials?.tokenAccountSupport == nil)
        #if os(macOS)
        #expect(descriptor.metadata.browserCookieOrder == [.chrome])
        #endif
        for source in ProviderCookieSource.allCases {
            let context = ProviderFetchContext(
                runtime: .cli,
                sourceMode: .web,
                includeCredits: false,
                webTimeout: 22,
                webDebugDumpHTML: false,
                verbose: false,
                env: [:],
                settings: .make(raycast: .init(cookieSource: source, manualCookieHeader: nil)),
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: RaycastUnusedClaudeFetcher(),
                browserDetection: BrowserDetection(
                    homeDirectory: "/nonexistent/raycast-fixture",
                    fileExists: { _ in false },
                    directoryContents: { _ in nil }))
            let strategy = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first)
            #expect(strategy.id == "raycast.js")
            #expect(strategy.kind == .web)
            #expect(await strategy.isAvailable(context) == (source != .off))
        }
    }
}

private struct RaycastUnusedClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw CancellationError() }
    func debugRawProbe(model _: String) async -> String { "unused" }
}
