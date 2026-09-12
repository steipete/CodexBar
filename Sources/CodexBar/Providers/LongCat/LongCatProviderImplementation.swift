import CodexBarCore
import Foundation

struct LongCatProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .longcat

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.longcatUsageDataSource
        _ = settings.longcatCookieSource
        _ = settings.longcatManualCookieHeader
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.longcatUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.longcatUsageDataSource {
        case .web: .web
        case .auto, .api, .cli, .oauth: .auto
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "longcat-cookie-source",
                context: context,
                source: \.longcatCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: "Automatic imports longcat.chat cookies from your browser.",
                        manual: "Paste a Cookie header copied from longcat.chat.",
                        off: "LongCat cookies are disabled.")
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "longcat-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}",
                binding: context.binding(\.longcatManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "longcat-open-console",
                        title: "Open Console",
                        url: URL(string: "https://longcat.chat/platform/")),
                ],
                isVisible: { context.settings.longcatCookieSource == .manual }),
        ]
    }
}
