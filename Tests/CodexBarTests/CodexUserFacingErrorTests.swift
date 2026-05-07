import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexUserFacingErrorTests {
    @Test
    func `expired codex auth is sanitized`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-expired-auth")
        store.errors[.codex] = """
        Codex connection failed: failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage \
        failed: 401 Unauthorized; content-type=text/plain; body={\"error\":{\"message\":\"Provided authentication \
        token is expired. Please try signing in again.\",\"code\":\"token_expired\"}}
        """

        #expect(store.userFacingError(for: .codex) == "Codex session expired. Sign in again.")
    }

    @Test
    func `transport codex error is sanitized`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-transport")
        store.errors[.codex] =
            "Codex connection failed: failed to fetch codex rate limits: "
                + "GET https://chatgpt.com/backend-api/wham/usage failed: 500"

        #expect(store.userFacingError(for: .codex) == "Codex usage is temporarily unavailable. Try refreshing.")
    }

    @Test
    func `decode mismatch codex error is sanitized`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-decode-mismatch")
        store.errors[.codex] =
            "Codex connection failed: failed to fetch codex rate limits: "
                + "Decode error for https://chatgpt.com/backend-api/wham/usage: "
                + "unknown variant `prolite`, expected one of `guest`, `free`, `go`, `plus`, `pro`"

        #expect(store.userFacingError(for: .codex) == "Codex usage is temporarily unavailable. Try refreshing.")
    }

    @Test
    func `cached credits failure preserves cached suffix while sanitizing body`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-cached-credits")
        store.lastCreditsError =
            "Last Codex credits refresh failed: Codex connection failed: failed to fetch codex rate limits: "
                + "GET https://chatgpt.com/backend-api/wham/usage failed: 500; body={\"error\":{}} "
                + "Cached values from 2m ago."

        #expect(
            store.userFacingLastCreditsError ==
                "Codex usage is temporarily unavailable. Try refreshing. Cached values from 2m ago.")
    }

    @Test
    func `browser mismatch remains unchanged`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-browser-mismatch")
        store.lastOpenAIDashboardError =
            "OpenAI cookies are for ratulsarna@gmail.com, not rdsarna@gmail.com. "
                + "Switch chatgpt.com account, then refresh OpenAI cookies."

        #expect(
            store.userFacingLastOpenAIDashboardError ==
                "OpenAI cookies are for ratulsarna@gmail.com, not rdsarna@gmail.com. "
                + "Switch chatgpt.com account, then refresh OpenAI cookies.")
    }

    @Test
    func `frame load interrupted becomes retry guidance`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-frame-load")
        store.lastOpenAIDashboardError = "Frame load interrupted"

        #expect(
            store.userFacingLastOpenAIDashboardError ==
                "OpenAI web refresh was interrupted. Refresh OpenAI cookies and try again.")
    }

    @Test
    func `open A I web timeout becomes retry guidance`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-openai-web-timeout")
        store.lastOpenAIDashboardError = "The operation couldn’t be completed. (NSURLErrorDomain error -1001.)"

        #expect(
            store.userFacingLastOpenAIDashboardError ==
                "OpenAI web refresh timed out. Refresh OpenAI cookies and try again.")
    }

    @Test
    func `open A I web network error becomes connection guidance`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-openai-web-network")
        store.lastOpenAIDashboardError = "The operation couldn’t be completed. (NSURLErrorDomain error -1004.)"
        let expected = [
            "OpenAI web refresh hit a network error.",
            "Check your connection, then refresh OpenAI cookies and try again.",
        ].joined(separator: " ")

        #expect(store.userFacingLastOpenAIDashboardError == expected)
    }

    @Test
    func `non codex providers keep raw errors`() {
        let store = self.makeUsageStore(suite: "CodexUserFacingErrorTests-non-codex")
        store.errors[.claude] = "Claude probe failed with debug detail"

        #expect(store.userFacingError(for: .claude) == "Claude probe failed with debug detail")
    }

    @Test
    func `providers pane codex model uses sanitized values`() {
        let settings = self.makeSettingsStore(suite: "CodexUserFacingErrorTests-pane-model")
        let store = self.makeUsageStore(settings: settings)
        store.errors[.codex] =
            "Codex connection failed: failed to fetch codex rate limits: "
                + "GET https://chatgpt.com/backend-api/wham/usage failed: 500"
        store.lastCreditsError =
            "Last Codex credits refresh failed: Codex connection failed: failed to fetch codex rate limits: "
                + "GET https://chatgpt.com/backend-api/wham/usage failed: 500 "
                + "Cached values from 1m ago."
        store.lastOpenAIDashboardError = "Frame load interrupted"

        let pane = ProvidersPane(settings: settings, store: store)
        let model = pane._test_menuCardModel(for: .codex)

        #expect(model.subtitleText == "Codex usage is temporarily unavailable. Try refreshing.")
        #expect(
            model.creditsHintText ==
                "OpenAI web refresh was interrupted. Refresh OpenAI cookies and try again.")
        #expect(
            model.creditsHintCopyText ==
                "OpenAI web refresh was interrupted. Refresh OpenAI cookies and try again.")
        #expect(
            model.creditsText == "Codex usage is temporarily unavailable. Try refreshing. Cached values from 1m ago.")
    }

    @Test
    func `providers pane codex error display keeps raw full text for copy`() {
        let settings = self.makeSettingsStore(suite: "CodexUserFacingErrorTests-pane-error-display")
        let store = self.makeUsageStore(settings: settings)
        let raw =
            "Codex connection failed: failed to fetch codex rate limits: "
                + "GET https://chatgpt.com/backend-api/wham/usage failed: 500; body={\"error\":{}}"
        store.errors[.codex] = raw

        let pane = ProvidersPane(settings: settings, store: store)
        let display = pane._test_providerErrorDisplay(for: .codex)

        #expect(display?.preview == "Codex usage is temporarily unavailable. Try refreshing.")
        #expect(display?.full == raw)
    }

    private func makeUsageStore(suite: String) -> UsageStore {
        let settings = self.makeSettingsStore(suite: suite)
        return self.makeUsageStore(settings: settings)
    }

    private func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
