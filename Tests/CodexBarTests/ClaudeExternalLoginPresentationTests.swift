import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(ClaudeOAuthDefaultsFixtures())
struct ClaudeExternalLoginPresentationTests {
    private struct StubCLI: ClaudeUsageFetching {
        let usage: ClaudeUsageSnapshot
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { self.usage }
        func debugRawProbe(model _: String) async -> String { "synthetic" }
        func detectVersion() -> String? { nil }
    }

    @Test(arguments: ["cli", "web", "failed-web", "cancelled-web"])
    func `Auto continues after changed credentials and preserves guidance if fallback fails`(
        fallback: String) async throws
    {
        let environment = ["HOME": "/synthetic/claude-relogin-\(UUID())"]
        let usage = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            rawText: nil)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: .make(claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .manual,
                manualCookieHeader: "sessionKey=sk-ant-synthetic-session")),
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: StubCLI(usage: usage),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let changed = ClaudeOAuthCredentialsError.credentialsChanged(Date(timeIntervalSince1970: 1_700_000_000))
        typealias Loader = @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials
        let loadCredentials: Loader = { _, _, _ in throw changed }
        let loadWeb: ClaudeWebFetchStrategy.UsageLoader = { _ in
            if fallback == "failed-web" { throw ClaudeWebAPIFetcher.FetchError.unauthorized }
            if fallback == "cancelled-web" { throw URLError(.cancelled) }
            return usage
        }
        let loadCLI: ClaudeStatusProbe.FetchOverride = { _, _, _ in
            ClaudeStatusSnapshot(
                sessionPercentLeft: 88,
                weeklyPercentLeft: nil,
                opusPercentLeft: nil,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil,
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                opusResetDescription: nil,
                rawText: "synthetic usage")
        }
        let outcome = await ProviderInteractionContext.$current.withValue(
            fallback == "cli" ? .userInitiated : .background)
        {
            await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(
                fallback == "cli" ? "/usr/bin/true" : "/synthetic/missing-claude")
            {
                await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredentials) {
                    await ClaudeWebFetchStrategy.$usageLoaderOverrideForTesting.withValue(loadWeb) {
                        await ClaudeStatusProbe.$fetchOverride.withValue(loadCLI) {
                            await ClaudeProviderDescriptor.descriptor.fetchOutcome(context: context)
                        }
                    }
                }
            }
        }
        #expect(outcome.attempts.first?.strategyID == "claude.oauth")
        #expect(outcome.attempts.first?.errorDescription == changed.localizedDescription)
        if fallback == "failed-web" || fallback == "cancelled-web" {
            guard case let .failure(error) = outcome.result else {
                Issue.record("Both live sources should have failed")
                return
            }
            if fallback == "cancelled-web" {
                #expect(ClaudeOAuthFetchError.isCancellation(error))
            } else {
                #expect(error.localizedDescription == changed.localizedDescription)
            }
        } else {
            let result = try outcome.result.get()
            #expect(result.sourceLabel == (fallback == "cli" ? "claude" : "web"))
            #expect(result.usage.primary?.usedPercent == 12)
        }
    }

    @Test
    @MainActor
    func `menu card and CLI JSON share the actionable message and the existing Refresh action`() throws {
        let error = ClaudeOAuthCredentialsError.credentialsChanged(Date(timeIntervalSince1970: 1_700_000_000))
        let model = Self.model(message: error.localizedDescription)
        #expect(model.subtitleText == error.localizedDescription)
        #expect(model.subtitleStyle == .error)
        #expect(!ProviderCredentialFailure.isAuthenticationFailure(error))
        let payload = CodexBarCLI.makeErrorPayload(error, kind: .provider)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(json["message"] as? String == model.subtitleText)
        #expect(MenuDescriptor.metaSection(updateReady: false).entries.contains {
            if case .action(_, .refresh) = $0 { return true }
            return false
        })
    }

    @Test
    @MainActor
    func `render synthetic external login guidance`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_RELOGIN_PROOF_DIR"] else { return }
        let after = ClaudeOAuthCredentialsError.credentialsChanged(Date(timeIntervalSinceNow: -120))
        for (name, error) in [("before", ClaudeOAuthCredentialsError.notFound), ("after", after)] {
            let hosting = NSHostingView(rootView: UsageMenuCardView(
                model: Self.model(message: error.localizedDescription), width: 340)
                .padding(16)
                .frame(width: 372)
                .environment(\.locale, Locale(identifier: "en"))
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(.light))
            hosting.appearance = NSAppearance(named: .aqua)
            let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    private static func model(message: String) -> UsageMenuCardView.Model {
        UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: ClaudeProviderDescriptor.descriptor.metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: ClaudeUIErrorMapper.userFacingMessage(message, staleSnapshotUpdatedAt: nil),
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)))
    }
}
