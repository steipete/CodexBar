import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderChangelogLinkTests {
    @Test
    func `known CLI providers declare changelog URLs`() {
        let metadata = ProviderDefaults.metadata

        #expect(metadata[.codex]?.changelogURL == "https://github.com/openai/codex/releases")
        #expect(metadata[.claude]?.changelogURL == "https://github.com/anthropics/claude-code/releases")
        #expect(metadata[.gemini]?.changelogURL == "https://github.com/google-gemini/gemini-cli/releases")
    }

    @Test
    func `provider menu hides changelog action until enabled`() {
        let codexDescriptor = self.makeDescriptor(
            provider: .codex,
            suite: "ProviderChangelogLinkTests-codex-default")
        #expect(!self.actionTitles(from: codexDescriptor).contains("Changelog"))
    }

    @Test
    func `provider menu shows changelog action only when setting and URL are present`() {
        let codexDescriptor = self.makeDescriptor(
            provider: .codex,
            suite: "ProviderChangelogLinkTests-codex",
            changelogLinksEnabled: true)
        #expect(self.actionTitles(from: codexDescriptor).contains("Changelog"))

        let openRouterDescriptor = self.makeDescriptor(
            provider: .openrouter,
            suite: "ProviderChangelogLinkTests-openrouter",
            changelogLinksEnabled: true)
        #expect(!self.actionTitles(from: openRouterDescriptor).contains("Changelog"))
    }

    private func makeDescriptor(
        provider: UsageProvider,
        suite: String,
        changelogLinksEnabled: Bool = false) -> MenuDescriptor
    {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.providerChangelogLinksEnabled = changelogLinksEnabled

        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        return MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false,
            includeContextualActions: true)
    }

    private func actionTitles(from descriptor: MenuDescriptor) -> [String] {
        descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .action(title, _) = entry else { return nil }
                return title
            }
    }
}
