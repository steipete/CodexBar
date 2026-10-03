import Foundation
import Testing
@testable import CodexBarCore

struct WorkBuddySettingsTests {
    @Test
    func `descriptor uses Chrome cookies and the shared script strategy`() async throws {
        let descriptor = WorkBuddyProviderDescriptor.descriptor
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
                settings: .make(workbuddy: .init(cookieSource: source, manualCookieHeader: nil)),
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: WorkBuddyUnusedClaudeFetcher(),
                browserDetection: BrowserDetection(
                    homeDirectory: "/nonexistent/workbuddy-fixture",
                    fileExists: { _ in false },
                    directoryContents: { _ in nil }))
            let strategy = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first)
            #expect(strategy.id == "workbuddy.js")
            #expect(strategy.kind == .web)
            #expect(await strategy.isAvailable(context) == (source != .off))
        }
    }
}

struct WorkBuddyChromeVersionTests {
    @Test
    func `installed Chrome supplies its major version`() {
        #if os(macOS)
        let major = WorkBuddyChromeVersion.majorVersion(homeDirectory: "/Users/fixture") { path in
            path == "/Applications/Google Chrome.app/Contents/Info.plist"
                ? ["CFBundleShortVersionString": "154.0.8037.95"]
                : nil
        }
        #expect(major == 154)
        #endif
    }

    @Test
    func `user Applications Chrome is the fallback`() {
        #if os(macOS)
        let major = WorkBuddyChromeVersion.majorVersion(homeDirectory: "/Users/fixture") { path in
            path == "/Users/fixture/Applications/Google Chrome.app/Contents/Info.plist"
                ? ["CFBundleShortVersionString": "153.0.1.2"]
                : nil
        }
        #expect(major == 153)
        #endif
    }

    @Test(arguments: [nil, "", "beta", "1.0.0", "0.9"])
    func `missing or invalid versions are omitted`(version: String?) {
        let major = WorkBuddyChromeVersion.majorVersion(homeDirectory: "/Users/fixture") { _ in
            version.map { ["CFBundleShortVersionString": $0] }
        }
        #expect(major == nil)
    }
}

private struct WorkBuddyUnusedClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw CancellationError() }
    func debugRawProbe(model _: String) async -> String { "unused" }
}
