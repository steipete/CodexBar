import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct CommandCodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .commandcode

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.commandcodeCookieSource
        _ = settings.commandcodeCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .commandcode(context.settings.commandcodeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.commandcodeCookieSource.rawValue },
            set: { raw in
                context.settings.commandcodeCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.commandcodeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from Command Code.",
                off: "Command Code cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "commandcode-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "commandcode-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.commandcodeCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "commandcode-open-settings",
                        title: "Open Command Code Settings",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://commandcode.ai/studio") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.commandcodeCookieSource == .manual },
                onActivate: { context.settings.ensureCommandCodeCookieLoaded() }),
        ]
    }
}
