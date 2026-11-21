import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct MiMoProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .mimo
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in context.store.sourceLabel(for: context.provider) }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .mimo, field: .apiKey]
        _ = settings[providerConfig: .mimo, field: .region]
        _ = settings.miMoCookieSource
        _ = settings.miMoCookieHeader
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderSettingsPickerDescriptor(
                id: "mimo-api-region",
                title: "API region",
                subtitle: "",
                binding: Binding(
                    get: { context.settings.providerConfig(for: .mimo)?.sanitizedRegion ?? "cn" },
                    set: { context.providerConfigBinding(.region).wrappedValue = $0 }),
                options: [.init(id: "cn", title: "China mainland"), .init(id: "sgp", title: "Singapore")],
                isVisible: nil,
                onChange: nil),
            ProviderCookieSourceUI.picker(
                id: "mimo-cookie-source",
                context: context,
                source: \.miMoCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies from Xiaomi MiMo."),
                        manual: L("Paste a Cookie header from %@.", "platform.xiaomimimo.com"),
                        off: L("%@ cookies are disabled.", "Xiaomi MiMo"))
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .mimo)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "mimo-api-key",
                title: "API key",
                subtitle: "Stored in the CodexBar config file.",
                kind: .secure,
                placeholder: "Paste API key…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [.openURL(
                    id: "mimo-open-token-plan",
                    title: "Open Token Plan",
                    url: URL(string: "https://mimo.mi.com/docs/en-US/api/asset/credits-get"))],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "mimo-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.miMoCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "mimo-open-balance",
                        title: "Open MiMo Balance",
                        url: URL(string: "https://platform.xiaomimimo.com/#/console/balance")),
                ],
                isVisible: { context.settings.miMoCookieSource == .manual }),
        ]
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        let loginURL = "https://platform.xiaomimimo.com/api/v1/genLoginUrl?currentPath=%2F%23%2Fconsole%2Fbalance"
        guard let url = URL(string: loginURL) else {
            return false
        }
        NSWorkspace.shared.open(url)
        return false
    }
}
