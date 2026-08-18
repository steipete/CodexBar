import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// The provider config revision gates publication of an in-flight refresh result. A cosmetic edit
/// must therefore leave it alone, because a cosmetic edit schedules no replacement fetch.
@MainActor
struct ProviderAccentRefreshRevisionTests {
    @Test
    func `changing the accent color leaves the provider refresh revision untouched`() {
        let settings = testSettingsStore(suiteName: "ProviderAccentRefreshRevisionTests-accent")
        let provider = UsageProvider.codex
        let before = settings.providerConfigRevision(for: provider)

        settings.setAccentColorOverride(ProviderColor(hex: 0xA56CC1), for: provider)

        #expect(settings.accentColorOverride(for: provider) == ProviderColor(hex: 0xA56CC1))
        #expect(settings.providerConfigRevision(for: provider) == before)
    }

    @Test
    func `resetting the accent color leaves the provider refresh revision untouched`() {
        let settings = testSettingsStore(suiteName: "ProviderAccentRefreshRevisionTests-reset")
        let provider = UsageProvider.codex
        settings.setAccentColorOverride(ProviderColor(hex: 0xA56CC1), for: provider)
        let before = settings.providerConfigRevision(for: provider)

        settings.setAccentColorOverride(nil, for: provider)

        #expect(settings.accentColorOverride(for: provider) == nil)
        #expect(settings.providerConfigRevision(for: provider) == before)
    }

    /// Control: a field a fetch actually depends on must still bump the revision, so the exclusion
    /// above cannot silently widen.
    @Test
    func `changing a fetch relevant field still bumps the provider refresh revision`() {
        let settings = testSettingsStore(suiteName: "ProviderAccentRefreshRevisionTests-control")
        let provider = UsageProvider.codex
        let before = settings.providerConfigRevision(for: provider)

        settings.updateProviderConfig(provider: provider) { $0.region = "us-east-1" }

        #expect(settings.providerConfigRevision(for: provider) > before)
    }
}
