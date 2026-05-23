import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct HiddenExtraRateWindowsTests {
    @Test
    func `hide and show extra rate windows per provider`() {
        let settings = Self.makeSettingsStore()
        let windowID = "test-window-123"
        let provider = UsageProvider.codex

        // Initially not hidden
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider) == false)

        // Hide the window
        settings.setExtraRateWindowHidden(windowID, provider: provider, hidden: true)
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider) == true)

        // Show the window again
        settings.setExtraRateWindowHidden(windowID, provider: provider, hidden: false)
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider) == false)
    }

    @Test
    func `hidden windows persist across app restarts`() throws {
        let suite = "HiddenExtraRateWindowsTests-persistence"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        var settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
        let windowID = "persistent-window-456"
        let provider = UsageProvider.claude

        // Hide a window
        settings.setExtraRateWindowHidden(windowID, provider: provider, hidden: true)
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider) == true)

        // Create new settings store (simulating app restart)
        settings = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        // Window should still be hidden
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider) == true)
    }

    @Test
    func `multiple hidden windows per provider`() {
        let settings = Self.makeSettingsStore()
        let provider = UsageProvider.gemini
        let window1 = "window-1"
        let window2 = "window-2"
        let window3 = "window-3"

        // Hide multiple windows
        settings.setExtraRateWindowHidden(window1, provider: provider, hidden: true)
        settings.setExtraRateWindowHidden(window2, provider: provider, hidden: true)
        settings.setExtraRateWindowHidden(window3, provider: provider, hidden: false)

        // Verify correct state
        #expect(settings.isExtraRateWindowHidden(window1, provider: provider) == true)
        #expect(settings.isExtraRateWindowHidden(window2, provider: provider) == true)
        #expect(settings.isExtraRateWindowHidden(window3, provider: provider) == false)

        // Get all hidden IDs for provider
        let hiddenIDs = settings.hiddenExtraRateWindowIDs(for: provider)
        #expect(hiddenIDs == [window1, window2])
    }

    @Test
    func `hidden windows are provider-specific`() {
        let settings = Self.makeSettingsStore()
        let windowID = "shared-window-id"
        let provider1 = UsageProvider.codex
        let provider2 = UsageProvider.claude

        // Hide window for provider1
        settings.setExtraRateWindowHidden(windowID, provider: provider1, hidden: true)

        // Same window ID should not be hidden for provider2
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider1) == true)
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider2) == false)

        // Hide for provider2
        settings.setExtraRateWindowHidden(windowID, provider: provider2, hidden: true)

        // Both should now be hidden
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider1) == true)
        #expect(settings.isExtraRateWindowHidden(windowID, provider: provider2) == true)
    }

    @Test
    func `hiddenExtraRateWindowIDs returns Set of hidden window IDs`() {
        let settings = Self.makeSettingsStore()
        let provider = UsageProvider.openai
        let ids = ["id-1", "id-2", "id-3"]

        // Hide all windows
        for id in ids {
            settings.setExtraRateWindowHidden(id, provider: provider, hidden: true)
        }

        let hiddenSet = settings.hiddenExtraRateWindowIDs(for: provider)
        #expect(hiddenSet.count == 3)
        #expect(hiddenSet.contains("id-1"))
        #expect(hiddenSet.contains("id-2"))
        #expect(hiddenSet.contains("id-3"))
        #expect(!hiddenSet.contains("id-4"))
    }

    @Test
    func `filtering extra rate windows in menu card model`() {
        let settings = Self.makeSettingsStore()
        let windowID1 = "visible-window"
        let windowID2 = "hidden-window"
        let provider = UsageProvider.codex

        // Hide one window
        settings.setExtraRateWindowHidden(windowID2, provider: provider, hidden: true)

        // Verify the hidden set is correct
        let hiddenIDs = settings.hiddenExtraRateWindowIDs(for: provider)

        // Simulate filtering (as done in MenuCardView)
        let allWindowIDs = [windowID1, windowID2]
        let visibleWindowIDs = allWindowIDs.filter { !hiddenIDs.contains($0) }

        #expect(visibleWindowIDs == [windowID1])
        #expect(visibleWindowIDs.count == 1)
    }

    // MARK: - Helpers

    private static func makeSettingsStore(suiteName: String = "HiddenExtraRateWindowsTests") -> SettingsStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suiteName)
        return Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
    }

    private static func makeSettingsStore(userDefaults: UserDefaults, configStore: CodexBarConfigStore) -> SettingsStore {
        SettingsStore(
            userDefaults: userDefaults,
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
