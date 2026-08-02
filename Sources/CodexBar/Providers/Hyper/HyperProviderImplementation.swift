import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct HyperProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .hyper

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.hyperAPIKey
        _ = settings.hyperCookieSource
        _ = settings.hyperCookieHeader
        _ = settings.tokenAccountsData(for: .hyper)
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .hyper(context.settings.hyperSettingsSnapshot())
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let binding = Binding(
            get: { context.settings.hyperCookieSource.rawValue },
            set: { raw in
                context.settings.hyperCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.hyperCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Prefer a signed-in Hyper session from Chrome, then fall back to an API key.",
                manual: "Paste a Cookie header from hyper.charm.land.",
                off: "Use only the configured API key.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "hyper-cookie-source",
                title: "Session source",
                subtitle: "Prefer a signed-in Hyper session, then fall back to an API key.",
                dynamicSubtitle: subtitle,
                binding: binding,
                options: options,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    ProviderCookieRefreshAction.trailingText(
                        provider: .hyper,
                        cookieSource: context.settings.hyperCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .hyper,
                        cookieSource: { context.settings.hyperCookieSource },
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "hyper-cookie",
                title: "Hyper cookie",
                subtitle: "Paste a Cookie header copied from a signed-in hyper.charm.land request.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.hyperCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "hyper-open-dashboard",
                        title: "Open Charm Hyper",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://hyper.charm.land") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.hyperCookieSource == .manual },
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "hyper-api-key",
                title: "API key",
                subtitle: "Fallback when no signed-in Hyper session is available. Stored in the CodexBar config file.",
                kind: .secure,
                placeholder: "Paste API key…",
                binding: context.stringBinding(\.hyperAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
