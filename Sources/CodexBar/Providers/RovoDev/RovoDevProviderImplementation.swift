import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct RovoDevProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .rovodev

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.rovodevCookieSource
        _ = settings.rovodevCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .rovodev(context.settings.rovodevSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.rovodevCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.rovodevCookieSource != .manual {
            settings.rovodevCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.rovodevCookieSource.rawValue },
            set: { raw in
                context.settings.rovodevCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.rovodevCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports cookies from your browser.",
                manual: "Paste a Cookie header captured from your Atlassian browser session.",
                off: "Rovo Dev cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "rovodev-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports cookies from your browser.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let siteURL: String = {
            if let config = try? RovoDevACLIConfig.load() {
                return "https://\(config.site)/rovodev/your-usage"
            }
            return "https://atlassian.net/rovodev/your-usage"
        }()

        return [
            ProviderSettingsFieldDescriptor(
                id: "rovodev-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.rovodevCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "rovodev-open-usage",
                        title: "Open Rovo Dev Usage",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: siteURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.rovodevCookieSource == .manual },
                onActivate: { context.settings.ensureRovoDevCookieLoaded() }),
        ]
    }
}
