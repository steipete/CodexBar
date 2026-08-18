import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct GrokProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .grok

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.grokUsageDataSource
        _ = settings.grokCookieSource
        _ = settings.grokCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.grokUsageDataSource
    }

    @MainActor
    func openTokenFile(context _: ProviderSettingsContext) -> Bool {
        let url = GrokCredentialsStore.tokenFileURLToOpen()
        try? FileManager.default.createDirectory(
            at: GrokCredentialsStore.grokHomeURL(),
            withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        return true
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext)
        -> ProviderSettingsSnapshotContribution?
    {
        .grok(context.settings.grokSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = Binding(
            get: { context.settings.grokUsageDataSource.rawValue },
            set: { raw in
                context.settings.grokUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        let sourceOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.cli.rawValue, title: "Grok CLI"),
            ProviderSettingsPickerOption(
                id: ProviderSourceMode.oauth.rawValue,
                title: "SuperGrok OAuth"),
            ProviderSettingsPickerOption(
                id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]
        let cookieBinding = Binding(
            get: { context.settings.grokCookieSource.rawValue },
            set: { raw in
                context.settings.grokCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.grokCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports grok.com cookies from Chrome.",
                manual: "Paste a Cookie header from a grok.com request.",
                off: "Grok cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "grok-usage-source",
                title: "Usage source",
                subtitle:
                "Auto tries the Grok CLI, SuperGrok OAuth, browser cookies, then bearer gRPC.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "grok-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports grok.com cookies from Chrome.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: {
                    context.settings.grokUsageDataSource == .auto
                        || context.settings.grokUsageDataSource == .web
                },
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "grok-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.grokCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "grok-open-usage",
                        title: "Open grok.com usage",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://grok.com/?_s=usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: {
                    (context.settings.grokUsageDataSource == .auto
                        || context.settings.grokUsageDataSource == .web)
                        && context.settings.grokCookieSource == .manual
                },
                onActivate: { context.settings.ensureGrokCookieLoaded() }),
        ]
    }
}
