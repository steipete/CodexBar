import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct DevinProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .devin
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.devinCookieSource
        _ = settings.devinBearerToken
        _ = settings.devinOrganization
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .devin(context.settings.devinSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.devinCookieSource.rawValue },
            set: { raw in
                context.settings.devinCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.devinCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically imports the app.devin.ai session from Chrome.",
                manual: "Paste an Authorization Bearer token from app.devin.ai.",
                off: "Paste an Authorization Bearer token from app.devin.ai.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "devin-cookie-source",
                title: "Auth source",
                subtitle: "Automatically imports the app.devin.ai session from Chrome.",
                dynamicSubtitle: subtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "devin-organization",
                title: "Organization",
                subtitle: "Optional. Use the slug from app.devin.ai/org/<slug>, or paste the full Devin org URL.",
                kind: .plain,
                placeholder: "org/example-org",
                binding: context.stringBinding(\.devinOrganization),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "devin-open-usage",
                        title: "Open Devin Usage",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(Self.usageURL(organization: context.settings.devinOrganization))
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "devin-bearer-token",
                title: "Bearer token",
                subtitle: "Paste the Authorization header value from app.devin.ai.",
                kind: .secure,
                placeholder: "Bearer eyJ...",
                binding: context.stringBinding(\.devinBearerToken),
                actions: [],
                isVisible: { context.settings.devinCookieSource == .manual },
                onActivate: nil),
        ]
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        ("Open Devin...", .loginToProvider(url: Self.usageURL(organization: nil).absoluteString))
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        let organization = context.controller.settings.devinOrganization
        NSWorkspace.shared.open(Self.usageURL(organization: organization))
        return false
    }

    private static func usageURL(organization: String?) -> URL {
        let normalized = DevinUsageFetcher.normalizedOrganization(organization)
        let urlString: String
        if let normalized, normalized.hasPrefix("org/") {
            let slug = String(normalized.dropFirst(4))
            urlString = "https://app.devin.ai/org/\(slug)/settings/usage"
        } else {
            urlString = "https://app.devin.ai/settings/usage"
        }
        return URL(string: urlString) ?? URL(string: "https://app.devin.ai")!
    }
}
