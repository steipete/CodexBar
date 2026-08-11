import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct ReplicateProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .replicate

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.replicateCookieSource
        _ = settings.replicateCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .replicate(context.settings.replicateSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.replicateCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.replicateCookieSource != .manual {
            settings.replicateCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.replicateCookieSource.rawValue },
            set: { raw in
                context.settings.replicateCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.replicateCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports Chrome cookies from replicate.com.",
                manual: "Paste a Cookie header captured from the billing page.",
                off: "Replicate cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "replicate-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports Chrome cookies from replicate.com.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .replicate)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "replicate-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a request to replicate.com/account/billing. "
                    + "Must contain a sessionid cookie.",
                kind: .secure,
                placeholder: "sessionid=…; csrftoken=…",
                binding: context.stringBinding(\.replicateCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "replicate-open-billing",
                        title: "Open Replicate Billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://replicate.com/account/billing") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.replicateCookieSource == .manual },
                onActivate: nil),
        ]
    }
}
