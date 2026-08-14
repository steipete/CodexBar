import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct MuseProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .muse

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web+api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.museAPIToken
        _ = settings.museBaseURL
        _ = settings.museCookieSource
        _ = settings.museCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext)
        -> ProviderSettingsSnapshotContribution?
    {
        .muse(context.settings.museSettingsSnapshot())
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MuseSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        context.settings.ensureMuseAPITokenLoaded()
        return context.settings.hasMuseAPIToken
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.museCookieSource.rawValue },
            set: { raw in context.settings.museCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.museCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports dev.meta.ai session (Team usage).",
                manual: "Paste Cookie header from dev.meta.ai → DevTools → Network → usage XHR.",
                off: "Muse cookies disabled.")
        }
        return [
            ProviderSettingsPickerDescriptor(
                id: "muse-cookie-source",
                title: "Team usage (dev.meta.ai)",
                subtitle: "Automatic imports dev.meta.ai session.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: { ProviderCookieSourceUI.cachedTrailingText(provider: .muse) }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "muse-api-key",
                title: "Meta Muse API key",
                subtitle: "API key from ai.developer.meta.com. Also accepts META_API_KEY.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.museAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "muse-open-dashboard",
                        title: "Open Meta developer console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(URL(string: "https://ai.developer.meta.com/")!)
                        }),
                    ProviderSettingsActionDescriptor(
                        id: "muse-open-usage",
                        title: "Open Team usage (dev.meta.ai)",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(URL(string: "https://dev.meta.ai/usage")!)
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMuseAPITokenLoaded() }),
            ProviderSettingsFieldDescriptor(
                id: "muse-base-url",
                title: "API base URL (optional)",
                subtitle: "Override for self-hosted or proxy. Default: https://api.meta.ai",
                kind: .plain,
                placeholder: "https://api.meta.ai",
                binding: context.stringBinding(\.museBaseURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "muse-cookie-header",
                title: "Cookie header (manual)",
                subtitle: "Paste Cookie header from dev.meta.ai → DevTools → Network → usage XHR → Request Headers",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.museCookieHeader),
                actions: [],
                isVisible: { context.settings.museCookieSource == .manual },
                onActivate: nil),
        ]
    }
}
