import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AugmentProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .augment

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.augmentCookieSource
        _ = settings.augmentCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .augment(context.settings.augmentSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.augmentCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.augmentCookieSource != .manual {
            settings.augmentCookieSource = .manual
        }
    }

    func makeRuntime() -> (any ProviderRuntime)? {
        AugmentProviderRuntime()
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.augmentCookieSource.rawValue },
            set: { raw in
                context.settings.augmentCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.augmentCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: L10n.tr("Automatic imports browser cookies."),
                manual: L10n.tr("Paste a Cookie header or cURL capture from the Augment dashboard."),
                off: L10n.tr("Augment cookies are disabled."))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "augment-cookie-source",
                title: L10n.tr("Cookie source"),
                subtitle: L10n.tr("Automatic imports browser cookies."),
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .augment) else { return nil }
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
    func appendActionMenuEntries(context: ProviderMenuActionContext, entries: inout [ProviderMenuEntry]) {
        entries.append(.action(L10n.tr("Refresh Session"), .refreshAugmentSession))

        if let error = context.store.error(for: .augment) {
            if error.contains("session has expired") ||
                error.contains("No Augment session cookie found")
            {
                entries.append(.action(
                    L10n.tr("Open Augment (Log Out & Back In)"),
                    .loginToProvider(url: "https://app.augmentcode.com")))
            }
        }
    }
}
