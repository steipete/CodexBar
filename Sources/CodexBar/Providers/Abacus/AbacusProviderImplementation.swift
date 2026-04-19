import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AbacusProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .abacus

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.abacusCookieSource
        _ = settings.abacusCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .abacus(context.settings.abacusSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.abacusCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.abacusCookieSource != .manual {
            settings.abacusCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.abacusCookieSource.rawValue },
            set: { raw in
                context.settings.abacusCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.abacusCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from the Abacus AI dashboard.",
                off: "Abacus AI cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "abacus-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .abacus) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "abacus-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste a cURL capture from the Abacus AI dashboard",
                binding: context.stringBinding(\.abacusCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "abacus-open-dashboard",
                        title: "Open Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://apps.abacus.ai/chatllm/admin/compute-points-usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.abacusCookieSource == .manual },
                onActivate: nil),
        ]
    }
}
