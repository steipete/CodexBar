import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct CursorProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cursor
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in L10n.tr("web") }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.cursorCookieSource
        _ = settings.cursorCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .cursor(context.settings.cursorSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.cursorCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.cursorCookieSource != .manual {
            settings.cursorCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.cursorCookieSource.rawValue },
            set: { raw in
                context.settings.cursorCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.cursorCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: L10n.tr("Automatic imports browser cookies or stored sessions."),
                manual: L10n.tr("Paste a Cookie header from a cursor.com request."),
                off: L10n.tr("Cursor cookies are disabled."))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "cursor-cookie-source",
                title: L10n.tr("Cookie source"),
                subtitle: L10n.tr("Automatic imports browser cookies or stored sessions."),
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .cursor) else { return nil }
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
        await context.controller.runCursorLoginFlow()
        return true
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard let cost = context.snapshot?.providerCost, cost.currencyCode != "Quota" else { return }
        let used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
        if cost.limit > 0 {
            let limitStr = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
            entries.append(.text(L10n.format("On-Demand: %@ / %@", used, limitStr), .primary))
        } else {
            entries.append(.text(L10n.format("On-Demand: %@", used), .primary))
        }
    }
}
