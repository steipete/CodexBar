import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct TraeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .trae

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.traeCookieSource
        _ = settings.traeCookieHeader
        _ = settings.tokenAccounts(for: .trae)
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .trae(context.settings.traeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let authBinding = Binding(
            get: { context.settings.traeCookieSource.rawValue },
            set: { raw in
                context.settings.traeCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let authOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let authSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.traeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically extracts JWT from browser cookies.",
                manual: "Paste JWT token (Cloud-IDE-JWT eyJ... or just eyJ...).",
                off: "Trae provider is disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "trae-auth-source",
                title: "Authentication source",
                subtitle: "Automatic extracts JWT from browser session.",
                dynamicSubtitle: authSubtitle,
                binding: authBinding,
                options: authOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "trae-jwt-token",
                title: "JWT Token",
                subtitle: "Paste your Trae JWT authentication token",
                kind: .secure,
                placeholder: "Cloud-IDE-JWT eyJ... or just eyJ...",
                binding: context.stringBinding(\.traeCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "trae-open-settings",
                        title: "Open Trae Settings",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.trae.ai/account-setting") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.traeCookieSource == .manual },
                onActivate: { context.settings.ensureTraeCookieLoaded() }),
        ]
    }
}
