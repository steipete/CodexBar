import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct MistralLinuxTests {
    @Test(arguments: [ProviderSourceMode.auto, .web])
    func `Mistral manual cookie header does not require browser support`(sourceMode: ProviderSourceMode) {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            sourceMode,
            provider: .mistral,
            settings: ProviderSettingsSnapshot.make(
                mistral: .init(cookieSource: .manual, manualCookieHeader: "Cookie: ory_session_test=1; csrftoken=2"))))
    }

    @Test(arguments: [ProviderSourceMode.auto, .web], [ProviderCookieSource.auto, .off])
    func `Mistral nonmanual cookie sources still require browser support`(
        sourceMode: ProviderSourceMode,
        cookieSource: ProviderCookieSource)
    {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            sourceMode,
            provider: .mistral,
            settings: ProviderSettingsSnapshot.make(
                mistral: .init(cookieSource: cookieSource, manualCookieHeader: "ory_session_test=1"))))
    }

    @Test(arguments: [ProviderSourceMode.auto, .web], [nil, "  ", "Cookie: \"\""] as [String?])
    func `Mistral manual source without a normalized header still requires browser support`(
        sourceMode: ProviderSourceMode,
        header: String?)
    {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            sourceMode,
            provider: .mistral,
            settings: ProviderSettingsSnapshot.make(
                mistral: .init(cookieSource: .manual, manualCookieHeader: header))))
    }

    @Test(arguments: [ProviderSourceMode.auto, .web])
    func `Mistral missing settings still require browser support`(sourceMode: ProviderSourceMode) {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(sourceMode, provider: .mistral))
    }

    @Test
    func `Mistral manual cookies retain session validation and do not expose the header`() async {
        let header = "csrftoken=synthetic-private-value"
        let settings = ProviderSettingsSnapshot.make(
            mistral: .init(cookieSource: .manual, manualCookieHeader: header))
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .mistral, settings: settings))
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let outcome = await MistralProviderDescriptor.descriptor.fetchPlan.fetchOutcome(
            context: context,
            provider: .mistral)
        #expect(outcome.attempts.map(\.strategyID) == ["mistral.web"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true])
        switch outcome.result {
        case .success:
            Issue.record("Expected a manual header without an ory_session cookie to fail before network access")
        case let .failure(error):
            #expect(error as? MistralSettingsError == .invalidCookie)
            #expect(!error.localizedDescription.contains("synthetic-private-value"))
        }
    }
}
