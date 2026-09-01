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
        _ = settings.museBrowserSource
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
        if context.settings.hasMuseAPIToken {
            return true
        }
        // Web mode: reflect configured cookie source without importing browser cookies.
        let source = context.settings.museCookieSource
        if source == .off {
            return false
        }
        if source == .manual {
            return !context.settings.museCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
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
        let browserBinding = Binding(
            get: { context.settings.museBrowserSource.rawValue },
            set: { raw in
                context.settings.museBrowserSource = MuseBrowserSource(rawValue: raw) ?? .auto
            })
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
            ProviderSettingsPickerDescriptor(
                id: "muse-browser-source",
                title: "Browser",
                subtitle: "Choose the browser that is signed in to dev.meta.ai.",
                binding: browserBinding,
                options: [
                    ProviderSettingsPickerOption(id: MuseBrowserSource.auto.rawValue, title: "Automatic"),
                    ProviderSettingsPickerOption(id: MuseBrowserSource.chrome.rawValue, title: "Google Chrome"),
                    ProviderSettingsPickerOption(id: MuseBrowserSource.brave.rawValue, title: "Brave Browser"),
                ],
                isVisible: { context.settings.museCookieSource == .auto },
                onChange: nil),
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
