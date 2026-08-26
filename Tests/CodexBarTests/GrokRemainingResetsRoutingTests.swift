import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct GrokRemainingResetsRoutingTests {
    @Test
    func `web strategy reuses the cookie that won billing for coupon lookup`() async throws {
        let capturedCookie = LockIsolated<String?>(nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try await GrokWebFetchStrategy().fetch(
            Self.webContext(includeOptionalUsage: true),
            webBilling: {
                (
                    GrokWebBillingSnapshot(usedPercent: 29, resetsAt: now.addingTimeInterval(86400)),
                    "Chrome Profile 2",
                    false,
                    "sso=winning")
            },
            settingsTier: { _ in nil },
            remainingResets: { credentials, cookieHeader, _ in
                #expect(credentials == nil)
                capturedCookie.setValue(cookieHeader)
                return GrokRemainingResetsLookupResult(
                    tokens: [
                        GrokRemainingReset(
                            tokenID: "restok_sample",
                            grantedAt: nil,
                            expiresAt: now.addingTimeInterval(172_800)),
                    ],
                    snapshotTask: nil)
            })

        #expect(capturedCookie.value == "sso=winning")
        #expect(result.usage.details.first?.rows.first?.value == "1 available")
    }

    @Test
    func `web strategy skips coupon lookup when optional usage is disabled`() async throws {
        let lookupCalled = LockIsolated(false)
        let result = try await GrokWebFetchStrategy().fetch(
            Self.webContext(includeOptionalUsage: false),
            webBilling: {
                (
                    GrokWebBillingSnapshot(usedPercent: 29, resetsAt: nil),
                    "Chrome",
                    false,
                    "sso=winning")
            },
            settingsTier: { _ in nil },
            remainingResets: { _, _, _ in
                lookupCalled.setValue(true)
                return .empty
            })

        #expect(!lookupCalled.value)
        #expect(result.usage.details.isEmpty)
    }

    @Test
    func `completion-required strategy awaits deferred coupon inventory`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = now.addingTimeInterval(172_800)
        let resetCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [expiresAt],
            updatedAt: now)
        let result = try await GrokWebFetchStrategy().fetch(
            Self.webContext(
                includeOptionalUsage: true,
                requiresOptionalUsageCompleteness: true),
            webBilling: {
                (
                    GrokWebBillingSnapshot(usedPercent: 29, resetsAt: now.addingTimeInterval(86400)),
                    "Chrome",
                    false,
                    "sso=winning")
            },
            settingsTier: { _ in nil },
            remainingResets: { _, _, _ in
                GrokRemainingResetsLookupResult(
                    tokens: [],
                    snapshotTask: Task { resetCredits })
            })

        #expect(result.usage.grokResetCredits == resetCredits)
        #expect(result.usage.details.first?.rows.first?.value == "1 available")
        #expect(result.supplementalUsageTask == nil)
    }

    @Test
    func `CLI completion-required result awaits deferred coupon inventory`() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = now.addingTimeInterval(172_800)
        let resetCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [expiresAt],
            updatedAt: now)
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(
                usedPercent: 29,
                resetsAt: now.addingTimeInterval(86400)),
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now)
        let result = await GrokCLIFetchStrategy().makeUsageResult(
            snapshot: snapshot,
            context: Self.webContext(
                includeOptionalUsage: true,
                requiresOptionalUsageCompleteness: true),
            resetLookup: GrokRemainingResetsLookupResult(
                tokens: [],
                snapshotTask: Task { resetCredits }))

        #expect(result.usage.grokResetCredits == resetCredits)
        #expect(result.usage.details.first?.rows.first?.value == "1 available")
        #expect(result.supplementalUsageTask == nil)
    }

    private static func webContext(
        includeOptionalUsage: Bool,
        requiresOptionalUsageCompleteness: Bool = false) -> ProviderFetchContext
    {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokResetRouting-\(UUID().uuidString)", isDirectory: true)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            includeOptionalUsage: includeOptionalUsage,
            requiresOptionalUsageCompleteness: requiresOptionalUsageCompleteness,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [
                "GROK_HOME": home.path,
                "GROK_CLI_PATH": home.appendingPathComponent("missing-grok").path,
                "PATH": home.path,
            ],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
