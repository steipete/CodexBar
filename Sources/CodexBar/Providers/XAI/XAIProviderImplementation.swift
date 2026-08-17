import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct XAIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .xai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: .xai)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .xai, field: .apiKey]
        _ = settings[providerConfig: .xai, field: .workspace]
        _ = settings.xaiUsageDataSource
        _ = settings.xaiCookieSource
        _ = settings.xaiCookieHeader
        _ = settings.xaiAllowGrokCLICredentials
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        let source = context.settings.xaiUsageDataSource
        if source == .web || (source == .auto && self.hasSuperGrokCookieCredential(context.settings)) {
            return true
        }
        if XAISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings[providerConfig: .xai, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        if XAISettingsReader.oauthToken(environment: context.environment) != nil {
            return true
        }
        if !context.settings.tokenAccounts(for: .xai).isEmpty {
            return true
        }
        if !context.settings.xaiCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if context.settings.xaiAllowGrokCLICredentials,
           (try? GrokCredentialsStore.load()) != nil
        {
            return true
        }
        return false
    }

    @MainActor
    private func hasSuperGrokCookieCredential(_ settings: SettingsStore) -> Bool {
        switch settings.xaiCookieSource {
        case .off:
            false
        case .manual:
            !settings.xaiCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || CookieHeaderCache.load(provider: .xai) != nil
        case .auto:
            true
        }
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.xaiUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.xaiUsageDataSource
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext)
        -> ProviderSettingsSnapshotContribution?
    {
        .xai(context.settings.xaiSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support _: TokenAccountSupport)
        -> Bool
    {
        let source = context.settings.xaiUsageDataSource
        return source == .auto || source == .oauth || source == .web
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.xaiCookieSource != .manual {
            settings.xaiCookieSource = .manual
        }
    }

    @MainActor
    static func revealGrokAuthFile() {
        let url = XAISettingsReader.grokAuthFileURL()
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = Binding(
            get: { context.settings.xaiUsageDataSource.rawValue },
            set: { raw in
                context.settings.xaiUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        let cookieBinding = Binding(
            get: { context.settings.xaiCookieSource.rawValue },
            set: { raw in
                context.settings.xaiCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.xaiCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports grok.com cookies from installed browsers.",
                manual: "Paste a Cookie header from a grok.com request.",
                off: "xAI SuperGrok cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "xai-usage-source",
                title: "Usage source",
                subtitle:
                "Auto uses the Management API when a key is present, then SuperGrok OAuth, then cookies.",
                binding: sourceBinding,
                options: [
                    ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
                    ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "Management API"),
                    ProviderSettingsPickerOption(id: ProviderSourceMode.oauth.rawValue, title: "SuperGrok OAuth"),
                    ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
                ],
                isVisible: nil,
                onChange: { _ in
                    await ProviderSettingsRefreshInteraction.perform {
                        await context.store.refreshProvider(.xai, allowDisabled: true)
                    }
                },
                trailingText: {
                    guard context.settings.xaiUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .xai)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "xai-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports grok.com cookies from installed browsers.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: {
                    context.settings.xaiUsageDataSource == .auto || context.settings.xaiUsageDataSource == .web
                },
                onChange: { _ in
                    await ProviderSettingsRefreshInteraction.perform {
                        await context.store.refreshProvider(.xai, allowDisabled: true)
                    }
                },
                trailingText: {
                    guard context.settings.xaiUsageDataSource == .web else { return nil }
                    return ProviderCookieRefreshAction.trailingText(
                        provider: .xai,
                        cookieSource: context.settings.xaiCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .xai,
                        cookieSource: { context.settings.xaiCookieSource },
                        additionalVisibility: { context.settings.xaiUsageDataSource == .web },
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        [
            ProviderSettingsToggleDescriptor(
                id: "xai-grok-cli-credentials",
                title: "Allow reading Grok CLI credentials",
                subtitle: [
                    "Read-only fallback to ~/.grok/auth.json from `grok login`.",
                    "CodexBar never refreshes or writes that file.",
                    "Off by default because this shares another app's SuperGrok session with xAI usage requests.",
                ].joined(separator: " "),
                binding: context.boolBinding(\.xaiAllowGrokCLICredentials),
                statusText: nil,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "xai-open-grok-auth-file",
                        title: "Open Grok auth file",
                        style: .link,
                        isVisible: { context.settings.xaiAllowGrokCLICredentials },
                        perform: {
                            Self.revealGrokAuthFile()
                        }),
                ],
                isVisible: {
                    context.settings.xaiUsageDataSource == .auto || context.settings.xaiUsageDataSource == .oauth
                },
                isEnabled: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "xai-management-api-key",
                title: "Management API key",
                subtitle: "Stored in ~/.codexbar/config.json. Create one at console.x.ai under "
                    + "Settings > Management Keys; inference API keys are not accepted.",
                kind: .secure,
                placeholder: "xai-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: {
                    context.settings.xaiUsageDataSource == .auto || context.settings.xaiUsageDataSource == .api
                },
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "xai-team-id",
                title: "Team ID",
                subtitle: "Required for Management API. Shown in the xAI Console URL and team settings.",
                kind: .plain,
                placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
                binding: context.providerConfigBinding(.workspace),
                actions: [],
                isVisible: {
                    context.settings.xaiUsageDataSource == .auto || context.settings.xaiUsageDataSource == .api
                },
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "xai-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.xaiCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "xai-open-grok",
                        title: "Open grok.com",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://grok.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: {
                    (context.settings.xaiUsageDataSource == .auto || context.settings.xaiUsageDataSource == .web)
                        && context.settings.xaiCookieSource == .manual
                },
                onActivate: { context.settings.ensureXAICookieLoaded() }),
        ]
    }
}
