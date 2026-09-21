import CodexBarCore
import Foundation
import SwiftUI

struct VeniceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .venice

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.veniceUsageDataSource
        _ = settings.veniceCookieSource
        _ = settings.veniceCookieHeader
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        // Web source reads the signed-in browser session, so cookie-only
        // setups without an API key are servable once selected.
        if context.settings.veniceUsageDataSource == .web {
            return true
        }
        if VeniceSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .venice).isEmpty
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.veniceUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.veniceUsageDataSource {
        case .auto: .auto
        case .api: .api
        case .web: .web
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.veniceUsageDataSource.rawValue },
            set: { raw in
                context.settings.veniceUsageDataSource = VeniceUsageDataSource(rawValue: raw) ?? .auto
            })
        let usageOptions = VeniceUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        return [
            ProviderSettingsPickerDescriptor(
                id: "venice-usage-source",
                title: "Usage source",
                subtitle: "Auto uses the API key. Web reads the signed-in venice.ai browser session.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil),
            ProviderCookieSourceUI.picker(
                id: "venice-cookie-source",
                context: context,
                source: \.veniceCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: "Automatic imports Venice cookies from Chrome.",
                        manual: "Paste a Cookie header from venice.ai.",
                        off: "Venice cookies are disabled.")
                },
                isVisible: { context.settings.veniceUsageDataSource == .web }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "venice-cookie",
            title: "",
            subtitle: "",
            kind: .secure,
            placeholder: "Cookie: …",
            binding: context.binding(\.veniceCookieHeader),
            actions: [],
            isVisible: {
                context.settings.veniceUsageDataSource == .web && context.settings.veniceCookieSource == .manual
            })]
    }
}
