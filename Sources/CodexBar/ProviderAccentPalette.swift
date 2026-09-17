import CodexBarCore
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Injected publication dependencies let isolated UI hosts prove they never discover the App Group.
@MainActor
struct ProviderAccentPublication {
    let isRunningTests: Bool
    let mirror: ([ProviderInstanceID: ProviderColor]) -> Bool
    let reloadWidgetTimelines: () -> Void

    static var live: Self {
        Self(
            isRunningTests: SettingsStore.isRunningTests,
            mirror: { ProviderAccentColors.mirrorToSharedDefaults($0) },
            reloadWidgetTimelines: {
                #if canImport(WidgetKit)
                WidgetCenter.shared.reloadAllTimelines()
                #endif
            })
    }
}

/// Resolved provider accent colors for the running app.
///
/// The helpers that color menu cards, charts, and switcher tabs are static and only receive a
/// provider, so the resolved map lives here instead of threading `SettingsStore` into each of them.
/// Some of those helpers are `nonisolated`, so a lock guards the map instead of an actor.
///
/// `SettingsStore` refreshes the palette whenever the config changes, from any origin: a settings
/// edit, an external edit to `~/.codexbar/config.json`, or an inbound iCloud sync.
enum ProviderAccentPalette {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var overrides: [ProviderInstanceID: ProviderColor] = [:]

    /// Refreshes the palette from the config and mirrors it to the App Group for the widget.
    /// Returns true when the mirrored copy changed, so the caller can reload widget timelines.
    ///
    /// The mirror always runs, never only when the in-memory map moves. The in-memory map starts
    /// empty at launch, so gating on it would leave a stale color in the App Group after someone
    /// edits the config file while the app is closed.
    @MainActor
    @discardableResult
    static func apply(
        config: CodexBarConfig,
        allowsSharedDefaults: Bool = true,
        publication: ProviderAccentPublication = .live) -> Bool
    {
        let resolved = ProviderAccentColors.overrides(in: config)
        self.lock.lock()
        self.overrides = resolved
        self.lock.unlock()
        // A test process can open the real App Group suite on a developer's Mac, so a test config
        // would otherwise overwrite the colors that developer actually uses.
        guard allowsSharedDefaults, !publication.isRunningTests else { return false }
        return publication.mirror(resolved)
    }

    /// The user override for a provider, or nil when the provider keeps its shipped color.
    static func override(for provider: UsageProvider) -> ProviderColor? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.overrides[provider.instanceID]
    }

    /// The color to paint with: the user override when one exists, otherwise the shipped brand color.
    static func color(for provider: UsageProvider) -> ProviderColor {
        self.override(for: provider) ?? ProviderDescriptorRegistry.descriptor(for: provider).branding.color
    }

    static func _test_reset() {
        self.lock.lock()
        self.overrides = [:]
        self.lock.unlock()
    }
}
