import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct MistralProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .mistral

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.mistralCookieSource
        _ = settings.mistralCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .mistral(context.settings.mistralSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.mistralCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.mistralCookieSource != .manual {
            settings.mistralCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.mistralCookieSource.rawValue },
            set: { raw in
                context.settings.mistralCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.mistralCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies from admin.mistral.ai.",
                manual: "Paste a Cookie header captured from the billing page.",
                off: "Mistral cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "mistral-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies from admin.mistral.ai.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .mistral) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "mistral-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a request to admin.mistral.ai. "
                    + "Must contain an ory_session_* cookie.",
                kind: .secure,
                placeholder: "ory_session_…=…; csrftoken=…",
                binding: context.stringBinding(\.mistralCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "mistral-open-console",
                        title: "Open Mistral Admin",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://admin.mistral.ai/organization/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.mistralCookieSource == .manual },
                onActivate: nil),
        ]
    }
}
