import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct T3ChatProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .t3chat

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.t3ChatCookieSource
        _ = settings.t3ChatCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .t3chat(context.settings.t3ChatSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.t3ChatCookieSource.rawValue },
            set: { raw in
                context.settings.t3ChatCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.t3ChatCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from T3 Chat settings.",
                off: "Paste a Cookie header or cURL capture from T3 Chat settings.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "t3chat-cookie-source",
                title: "Cookie source",
                subtitle: "Automatically imports browser cookies.",
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
                id: "t3chat-cookie",
                title: "T3 Chat cookie",
                subtitle: "Paste a Cookie header or full cURL capture from T3 Chat settings.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.t3ChatCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "t3chat-open-settings",
                        title: "Open T3 Chat Settings",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://t3.chat/settings/customization") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.t3ChatCookieSource == .manual },
                onActivate: nil),
        ]
    }
}
