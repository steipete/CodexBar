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
                subtitle: "Tracks the Kimi Code subscription only (api.kimi.com weekly quota). " +
                    "Auto tries your Code API key, then a signed-in Kimi Code CLI credential, then browser cookies. " +
                    "China open-platform balance (api.moonshot.cn) is a different product — enable " +
                    "Moonshot / Kimi Open Platform and set API region to China mainland.",
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
                subtitle: "Automatic imports browser cookies from kimi.com (Code console).",
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
                title: "Kimi Code API key",
                subtitle: "Code subscription key from www.kimi.com/code (not platform.kimi.com open-platform keys). " +
                    "Stored in ~/.codexbar/config.json. You can also provide KIMI_CODE_API_KEY. " +
                    "For China open-platform balance, use Moonshot / Kimi Open Platform instead.",
                kind: .secure,
                placeholder: "Paste Kimi Code API key...",
                binding: context.stringBinding(\.kimiAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-open-api-docs",
                        title: "Open Code docs",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.kimi.com/code/docs/en/") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                    ProviderSettingsActionDescriptor(
                        id: "kimi-open-open-platform-china",
                        title: "China open platform",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            // Jump to the product that actually has a China API host.
                            if let url = URL(string: "https://platform.kimi.com/console/account") {
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
                        title: "Open Code console",
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
