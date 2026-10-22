import AppKit
import CodexBarCore
import Foundation

struct TraeCNProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .traecn
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.traeCNCookieSource
        _ = settings.traeCNCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        // Resolve with the same Manual fallback the settings UI shows: a fresh Trae CN
        // configuration has no stored source, and the default auto fallback would reject its cookie.
        .traecn(context.settings.traeCNSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        // Trae CN has no browser import, so Manual and Off are the only meaningful choices.
        let subtitles: ProviderCookieSourceUI.Subtitles = .init(
            auto: L("Trae CN has no browser import. Select Manual to paste a Cookie header."),
            manual: L("Uses the Cookie header pasted from a signed-in trae.cn session."),
            off: L("%@ authentication is disabled.", "Trae CN"))
        return [
            ProviderSettingsPickerDescriptor(
                id: "traecn-cookie-source",
                title: "Cookie source",
                subtitle: subtitles.manual,
                dynamicSubtitle: {
                    ProviderCookieSourceUI.subtitle(
                        source: context.settings.traeCNCookieSource,
                        keychainDisabled: context.settings.debugDisableKeychainAccess,
                        auto: subtitles.auto,
                        manual: subtitles.manual,
                        off: subtitles.off)
                },
                binding: context.rawValueBinding(\.traeCNCookieSource, fallback: .manual),
                options: [
                    ProviderSettingsPickerOption(
                        id: ProviderCookieSource.manual.rawValue,
                        title: ProviderCookieSource.manual.displayName),
                    ProviderSettingsPickerOption(
                        id: ProviderCookieSource.off.rawValue,
                        title: ProviderCookieSource.off.displayName),
                ],
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "traecn-cookie",
                title: L("Cookie"),
                subtitle: L(
                    "Paste a Cookie header from %@ (DevTools → Network → any api.trae.cn request).",
                    "www.trae.cn"),
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.traeCNCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "traecn-open-dashboard",
                        title: L("Open Trae CN Dashboard"),
                        url: URL(string: "https://www.trae.cn/dashboard")),
                ],
                isVisible: { context.settings.traeCNCookieSource == .manual }),
        ]
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        guard let url = URL(string: "https://www.trae.cn/dashboard") else {
            return false
        }
        NSWorkspace.shared.open(url)
        return false
    }
}
