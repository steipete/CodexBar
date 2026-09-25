import CodexBarCore
import Foundation

struct RaycastProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .raycast

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.raycastCookieSource
        _ = settings.raycastCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .raycast(context.settings.raycastSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [ProviderCookieSourceUI.picker(
            id: "raycast-cookie-source",
            context: context,
            source: \.raycastCookieSource,
            allowsOff: true,
            subtitles: {
                .init(
                    auto: L("Automatic imports Chrome cookies from www.raycast.com."),
                    manual: L("Paste a Cookie header captured from %@.", "the account settings page"),
                    off: L("%@ cookies are disabled.", "Raycast"))
            },
            trailingText: {
                ProviderCookieRefreshAction.trailingText(
                    provider: .raycast,
                    cookieSource: context.settings.raycastCookieSource,
                    context: context)
            },
            trailingActions: [
                ProviderCookieRefreshAction.descriptor(
                    provider: .raycast,
                    cookieSource: { context.settings.raycastCookieSource },
                    context: context),
            ])]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "raycast-cookie-header",
            title: "Cookie header",
            subtitle: "Paste the Cookie header from a www.raycast.com/settings request. It must contain __raycast_session.",
            kind: .secure,
            placeholder: "__raycast_session=…; csrf_token=…",
            binding: context.binding(\.raycastCookieHeader),
            actions: [.openURL(
                id: "raycast-open-settings",
                title: "Open Raycast Account",
                url: URL(string: "https://www.raycast.com/settings"))],
            isVisible: { context.settings.raycastCookieSource == .manual })]
    }
}
