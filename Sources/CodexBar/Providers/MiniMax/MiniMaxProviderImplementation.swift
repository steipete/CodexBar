import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct MiniMaxProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .minimax

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.minimaxCookieSource
        _ = settings.minimaxCookieHeader
        _ = settings.minimaxAPIToken
        _ = settings.minimaxAPIRegion
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .minimax(context.settings.minimaxSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        context.settings.ensureMiniMaxAPITokenLoaded()
        if context.settings.minimaxAuthMode().usesAPIToken { return false }
        return context.settings.minimaxCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.minimaxCookieSource != .manual {
            settings.minimaxCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        context.settings.ensureMiniMaxAPITokenLoaded()
        let authMode: () -> MiniMaxAuthMode = {
            context.settings.minimaxAuthMode()
        }

        let cookieBinding = Binding(
            get: { context.settings.minimaxCookieSource.rawValue },
            set: { raw in
                context.settings.minimaxCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.minimaxCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies and local storage tokens.",
                manual: "Paste a Cookie header or cURL capture from the Coding Plan page.",
                off: "MiniMax cookies are disabled.")
        }

        let regionBinding = Binding(
            get: { context.settings.minimaxAPIRegion.rawValue },
            set: { raw in
                context.settings.minimaxAPIRegion = MiniMaxAPIRegion(rawValue: raw) ?? .global
            })
        let regionOptions = MiniMaxAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "minimax-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies and local storage tokens.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: { authMode().allowsCookies },
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .minimax) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
            ProviderSettingsPickerDescriptor(
                id: "minimax-region",
                title: "API region",
                subtitle: "Choose the MiniMax host (global .io or China mainland .com).",
                binding: regionBinding,
                options: regionOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        context.settings.ensureMiniMaxAPITokenLoaded()
        let authMode: () -> MiniMaxAuthMode = {
            context.settings.minimaxAuthMode()
        }

        return [
            ProviderSettingsFieldDescriptor(
                id: "minimax-api-token",
                title: "API token",
                subtitle: "Stored in ~/.codexbar/config.json. Paste your MiniMax API key.",
                kind: .secure,
                placeholder: "Paste API token…",
                binding: context.stringBinding(\.minimaxAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "minimax-open-dashboard",
                        title: "Open Coding Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(
                                string: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMiniMaxAPITokenLoaded() }),
            ProviderSettingsFieldDescriptor(
                id: "minimax-cookie",
                title: "Cookie header",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.minimaxCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "minimax-open-dashboard-cookie",
                        title: "Open Coding Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(
                                string: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: {
                    authMode().allowsCookies && context.settings.minimaxCookieSource == .manual
                },
                onActivate: { context.settings.ensureMiniMaxCookieLoaded() }),
        ]
    }
}
