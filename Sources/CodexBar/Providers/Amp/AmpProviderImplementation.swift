import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct AmpProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .amp

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.ampUsageDataSource
        _ = settings.ampAPIToken
        _ = settings.ampCookieSource
        _ = settings.ampCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.ampUsageDataSource
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .amp(context.settings.ampSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = Binding(
            get: { context.settings.ampUsageDataSource.rawValue },
            set: { raw in
                context.settings.ampUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        let sourceOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.cli.rawValue, title: "Amp CLI"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "Access token"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]
        let cookieBinding = Binding(
            get: { context.settings.ampCookieSource.rawValue },
            set: { raw in
                context.settings.ampCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.ampCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from Amp settings.",
                off: "Amp cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "amp-usage-source",
                title: "Usage source",
                subtitle: "Auto tries the Amp CLI, access token, then browser cookies.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "amp-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: {
                    context.settings.ampUsageDataSource == .auto ||
                        context.settings.ampUsageDataSource == .web
                },
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "amp-api-token",
                title: "Access token",
                subtitle: "Stored in ~/.codexbar/config.json. You can also set AMP_API_KEY.",
                kind: .secure,
                placeholder: "sgamp_...",
                binding: context.stringBinding(\.ampAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "amp-open-access-tokens",
                        title: "Open Amp Access Tokens",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://ampcode.com/settings") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: {
                    context.settings.ampUsageDataSource == .auto ||
                        context.settings.ampUsageDataSource == .api
                },
                onActivate: { context.settings.ensureAmpAPITokenLoaded() }),
            ProviderSettingsFieldDescriptor(
                id: "amp-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.ampCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "amp-open-settings",
                        title: "Open Amp Settings",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://ampcode.com/settings") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: {
                    (context.settings.ampUsageDataSource == .auto ||
                        context.settings.ampUsageDataSource == .web) &&
                        context.settings.ampCookieSource == .manual
                },
                onActivate: { context.settings.ensureAmpCookieLoaded() }),
        ]
    }
}
