import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ClaudeTokenAccountSourceModeTests {
    @Test
    func `source pointer account reroutes explicit CLI source to OAuth in app`() {
        let settings = testSettingsStore(suiteName: "ClaudeTokenAccountSourceModeTests-source-app")
        settings.claudeUsageDataSource = .cli
        let source = ClaudeCredentialSource.credentialsFile(path: "/tmp/claude-account/.credentials.json")
        let token = source.encodedTokenValue()
        settings.addTokenAccount(provider: .claude, label: "OAuth Source", token: token)
        let store = Self.makeUsageStore(settings: settings)

        let context = store.makeFetchContext(provider: .claude, override: nil)

        #expect(context.sourceMode == .oauth)
        #expect(context.selectedTokenAccountID == settings.selectedTokenAccount(for: .claude)?.id)
        #expect(context.env[ClaudeCredentialSource.environmentDescriptorKey] == token)
    }

    @Test
    func `session account reroutes explicit CLI source to Web in app`() {
        let settings = testSettingsStore(suiteName: "ClaudeTokenAccountSourceModeTests-session-app")
        settings.claudeUsageDataSource = .cli
        settings.addTokenAccount(provider: .claude, label: "Session", token: "sk-ant-session-token")
        let store = Self.makeUsageStore(settings: settings)

        let context = store.makeFetchContext(provider: .claude, override: nil)

        #expect(context.sourceMode == .web)
        #expect(context.settings?.claude?.cookieSource == .manual)
        #expect(context.settings?.claude?.manualCookieHeader == "sessionKey=sk-ant-session-token")
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }
}
