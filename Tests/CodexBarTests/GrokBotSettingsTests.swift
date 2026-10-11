import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct GrokBotSettingsTests {
    @Test
    func `no Keychain mode keeps automatic Cursor app sessions available for Grok Bot`() throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "GrokBotSettingsTests-no-keychain")
        defer { fixture.settings.configFileWatcher?.stop() }
        let prior = fixture.settings.debugDisableKeychainAccess
        defer { fixture.settings.debugDisableKeychainAccess = prior }
        fixture.settings.debugDisableKeychainAccess = true
        fixture.settings.grokBotUsageEnabled = true
        let automatic = ProviderRegistry.makeSettingsSnapshot(settings: fixture.settings, tokenOverride: nil)
        #expect(automatic.cursor?.cookieSource == .manual)
        #expect(CookieHeaderNormalizer.normalize(automatic.cursor?.manualCookieHeader) == nil)
        #expect(automatic.grok?.grokBotCursorCookieSource == .auto)

        fixture.settings.cursorCookieSource = .manual
        let explicitManual = ProviderRegistry.makeSettingsSnapshot(settings: fixture.settings, tokenOverride: nil)
        #expect(explicitManual.grok?.grokBotCursorCookieSource == nil)
        fixture.settings.cursorCookieSource = .off
        let disabled = ProviderRegistry.makeSettingsSnapshot(settings: fixture.settings, tokenOverride: nil)
        #expect(disabled.cursor?.cookieSource == .off)
        #expect(disabled.grok?.grokBotCursorCookieSource == nil)

        fixture.settings.cursorCookieSource = .auto
        fixture.settings.cursorCookieHeader = "WorkosCursorSessionToken=explicit-fixture"
        let supplied = ProviderRegistry.makeSettingsSnapshot(settings: fixture.settings, tokenOverride: nil)
        #expect(supplied.cursor?.manualCookieHeader == "WorkosCursorSessionToken=explicit-fixture")
        #expect(supplied.grok?.grokBotCursorCookieSource == nil)
    }

    @Test
    func `Grok Bot tracking defaults off persists both states and keeps Cursor credentials separate`() throws {
        let suite = "GrokBotSettingsTests-settings"
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: suite)
        defer { fixture.settings.configFileWatcher?.stop() }
        let toggle = try #require(GrokProviderImplementation()
            .settingsToggles(context: fixture.settingsContext(provider: .grok))
            .first { $0.id == "grok-bot-usage" })
        #expect(toggle.title == "Track Grok Bot usage")
        #expect(!toggle.binding.wrappedValue)
        #expect(fixture.settings.providerConfig(for: .grok)?.grokBotUsageEnabled == nil)
        fixture.settings.grokCookieHeader = "sso=grok-fixture"
        fixture.settings.cursorCookieSource = .manual
        fixture.settings.cursorCookieHeader = "WorkosCursorSessionToken=cursor-fixture"
        toggle.binding.wrappedValue = true
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: fixture.settings, tokenOverride: nil)
        #expect(snapshot.grok?.grokBotUsageEnabled == true)
        #expect(snapshot.grok?.manualCookieHeader == "sso=grok-fixture")
        #expect(snapshot.cursor?.manualCookieHeader == "WorkosCursorSessionToken=cursor-fixture")
        #expect(fixture.settings.isProviderEnabled(
            provider: .cursor, metadata: CursorProviderDescriptor.descriptor.metadata) == false)
        fixture.store.snapshots[.grok] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: CursorSandUsageStatus.extraWindowID,
                title: CursorSandUsageStatus.extraWindowTitle,
                window: RateWindow(usedPercent: 42, windowMinutes: nil, resetsAt: nil, resetDescription: nil))],
            updatedAt: Date())
        #expect(fixture.store.snapshot(for: .grok)?.extraRateWindows?.count == 1)
        toggle.binding.wrappedValue = false
        #expect(fixture.store.snapshot(for: .grok)?.extraRateWindows == nil)
        toggle.binding.wrappedValue = true

        let reopened = SettingsStore(
            userDefaults: InMemoryUserDefaults(),
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        defer { reopened.configFileWatcher?.stop() }
        #expect(reopened.grokBotUsageEnabled)
        reopened.grokBotUsageEnabled = false
        let reopenedOff = SettingsStore(
            userDefaults: InMemoryUserDefaults(),
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        defer { reopenedOff.configFileWatcher?.stop() }
        #expect(!reopenedOff.grokBotUsageEnabled)
    }
}
