import CodexBarCore
import Foundation

/// Minimal implementation to satisfy the provider manifest generator. Settings UI
/// (cookie source picker, manual header field, settings store bindings) lands separately.
struct ReplicateProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .replicate

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.replicateCookieSource
        _ = settings.replicateCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .replicate(context.settings.replicateSettingsSnapshot(tokenOverride: context.tokenOverride))
    }
}
