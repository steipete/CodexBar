import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct FactoryProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .factory
    let supportsLoginFlow: Bool = true

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.factoryCookieSource
        _ = settings.factoryCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .factory(context.settings.factorySettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.factoryCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.factoryCookieSource != .manual {
            settings.factoryCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.factoryCookieSource.rawValue },
            set: { raw in
                context.settings.factoryCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.factoryCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: L10n.tr("Automatic imports browser cookies and WorkOS tokens."),
                manual: L10n.tr("Paste a Cookie header from app.factory.ai."),
                off: L10n.tr("Factory cookies are disabled."))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "factory-cookie-source",
                title: L10n.tr("Cookie source"),
                subtitle: L10n.tr("Automatic imports browser cookies and WorkOS tokens."),
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .factory) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return L10n.format("Cached: %@ • %@", entry.sourceLabel, when)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        _ = context
        return []
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runFactoryLoginFlow()
        return true
    }
}
