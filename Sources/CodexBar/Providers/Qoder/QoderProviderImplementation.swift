import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct QoderProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .qoder

    @MainActor
    static func usageDashboardURL(settings: SettingsStore) -> URL {
        QoderProviderDescriptor.dashboardURL(
            settings: settings.qoderSettingsSnapshot(tokenOverride: nil),
            sourceLabel: nil)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.qoderCookieSource
        _ = settings.qoderCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .qoder(context.settings.qoderSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.qoderCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.qoderCookieSource != .manual {
            settings.qoderCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.qoderCookieSource.rawValue },
            set: { raw in
                context.settings.qoderCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.qoderCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from Qoder usage.",
                off: "Qoder cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "qoder-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.loadForDisplay(provider: .qoder) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "qoder-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}\n\nor paste a cURL capture from the Qoder usage page",
                binding: context.stringBinding(\.qoderCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "qoder-open-usage",
                        title: "Open Qoder Usage",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(Self.usageDashboardURL(settings: context.settings))
                        }),
                ],
                isVisible: { context.settings.qoderCookieSource == .manual },
                onActivate: { context.settings.ensureQoderCookieLoaded() }),
        ]
    }
}
