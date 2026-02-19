import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct OpenCodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .opencode

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in L10n.tr("web") }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.opencodeCookieSource
        _ = settings.opencodeCookieHeader
        _ = settings.opencodeWorkspaceID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .opencode(context.settings.opencodeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.opencodeCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.opencodeCookieSource != .manual {
            settings.opencodeCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.opencodeCookieSource.rawValue },
            set: { raw in
                context.settings.opencodeCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.opencodeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: L10n.tr("Automatic imports browser cookies from opencode.ai."),
                manual: L10n.tr("Paste a Cookie header captured from the billing page."),
                off: L10n.tr("OpenCode cookies are disabled."))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "opencode-cookie-source",
                title: L10n.tr("Cookie source"),
                subtitle: L10n.tr("Automatic imports browser cookies from opencode.ai."),
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .opencode) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return L10n.format("Cached: %@ • %@", entry.sourceLabel, when)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "opencode-workspace-id",
                title: L10n.tr("Workspace ID"),
                subtitle: L10n.tr("Optional override if workspace lookup fails."),
                kind: .plain,
                placeholder: L10n.tr("wrk_..."),
                binding: context.stringBinding(\.opencodeWorkspaceID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
