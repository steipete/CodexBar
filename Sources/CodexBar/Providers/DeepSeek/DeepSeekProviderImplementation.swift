import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct DeepSeekProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .deepseek

    private static let usageDashboardURL = URL(string: "https://platform.deepseek.com/usage")!

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.deepSeekCookieSource
        _ = settings.deepSeekCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .deepseek(context.settings.deepSeekSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if DeepSeekSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.tokenAccounts(for: .deepseek).isEmpty
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.deepSeekCookieSource.rawValue },
            set: { raw in
                context.settings.deepSeekCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.deepSeekCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies from platform.deepseek.com on user-initiated refresh.",
                manual: "Paste a Cookie or Authorization header captured from platform.deepseek.com.",
                off: "DeepSeek usage summaries are disabled; only API balance is shown.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "deepseek-cookie-source",
                title: "Usage summary source",
                subtitle: "Usage amount/cost endpoints require a platform web session.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.loadForDisplay(provider: .deepseek) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "deepseek-platform-session",
                title: "Platform session",
                subtitle: "Paste the Cookie or Authorization header from a request to "
                    + "platform.deepseek.com (DevTools → Network → usage API).",
                kind: .secure,
                placeholder: "Cookie: … or Bearer …",
                binding: context.stringBinding(\.deepSeekCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "deepseek-open-usage",
                        title: "Open Usage Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://platform.deepseek.com/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.deepSeekCookieSource == .manual },
                onActivate: nil),
        ]
    }

    @MainActor
    func settingsActions(context _: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        [
            ProviderSettingsActionsDescriptor(
                id: "deepseek-usage-dashboard",
                title: "Usage dashboard",
                subtitle: "Open platform.deepseek.com for billing history and usage charts.",
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "deepseek-open-usage-dashboard",
                        title: "Open Usage Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(Self.usageDashboardURL)
                        }),
                ],
                isVisible: nil),
        ]
    }
}
