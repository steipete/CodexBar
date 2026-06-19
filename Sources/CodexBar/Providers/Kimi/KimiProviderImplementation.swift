import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct KimiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimi

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.kimiUsageDataSource
        _ = settings.kimiAPIKey
        _ = settings.kimiCookieSource
        _ = settings.kimiManualCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .kimi(context.settings.kimiSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.kimiUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.kimiUsageDataSource {
        case .api: .api
        case .web: .web
        case .auto, .cli, .oauth: .auto
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.kimiUsageDataSource.rawValue },
            set: { raw in
                context.settings.kimiUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        let usageOptions = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API key"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]

        let cookieBinding = Binding(
            get: { context.settings.kimiCookieSource.rawValue },
            set: { raw in
                context.settings.kimiCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.kimiCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste a cookie header or the kimi-auth token value.",
                off: "Kimi cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "kimi-usage-source",
                title: "Usage source",
                subtitle: "Auto uses the Kimi Code API key first, then falls back to browser cookies.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.kimiUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .kimi)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "kimi-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: subtitle,
                binding: cookieBinding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kimi-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide KIMI_CODE_API_KEY.",
                kind: .secure,
                placeholder: "Paste Kimi Code API key...",
                binding: context.stringBinding(\.kimiAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-open-api-docs",
                        title: "Open API docs",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.kimi.com/code/docs/en/") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "kimi-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste the kimi-auth token value",
                binding: context.stringBinding(\.kimiManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-open-console",
                        title: "Open Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.kimi.com/code/console") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.kimiCookieSource == .manual },
                onActivate: { context.settings.ensureKimiAuthTokenLoaded() }),
        ]
    }
}
