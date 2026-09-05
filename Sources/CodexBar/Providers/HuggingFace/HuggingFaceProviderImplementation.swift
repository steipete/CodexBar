import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct HuggingFaceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .huggingface

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.huggingFaceUsageDataSource
        _ = settings[providerConfig: .huggingface, field: .apiKey]
        _ = settings.huggingFaceCookieSource
        _ = settings.huggingFaceManualCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.huggingFaceUsageDataSource
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .huggingface(context.settings.huggingFaceSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if HuggingFaceSettingsReader.token(environment: context.environment) != nil {
            return true
        }
        if !context.settings[providerConfig: .huggingface, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        {
            return true
        }

        return switch context.settings.huggingFaceCookieSource {
        case .auto:
            true
        case .manual:
            CookieHeaderNormalizer.normalize(context.settings.huggingFaceManualCookieHeader) != nil
        case .off:
            false
        }
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "huggingface-api-token",
                title: "API token",
                subtitle: "Stored in ~/.codexbar/config.json. Create a user access token at huggingface.co/settings/tokens.",
                kind: .secure,
                placeholder: "hf_...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "huggingface-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …\n\nor paste a full Cookie header",
                binding: context.stringBinding(\.huggingFaceManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "huggingface-open-billing",
                        title: "Open Hugging Face Billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://huggingface.co/settings/billing") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.huggingFaceCookieSource == .manual },
                onActivate: nil),
        ]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = Binding(
            get: { context.settings.huggingFaceUsageDataSource.rawValue },
            set: { raw in
                context.settings.huggingFaceUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        let sourceOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API token"),
        ]
        let cookieBinding = Binding(
            get: { context.settings.huggingFaceCookieSource.rawValue },
            set: { raw in
                context.settings.huggingFaceCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.huggingFaceCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically imports Hugging Face browser session cookies.",
                manual: "Paste a full Cookie header from the Hugging Face billing page.",
                off: "Hugging Face billing cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "huggingface-cookie-source",
                title: "Cookie source",
                subtitle: "Automatically imports Hugging Face browser session cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    ProviderCookieRefreshAction.trailingText(
                        provider: .huggingface,
                        cookieSource: context.settings.huggingFaceCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .huggingface,
                        cookieSource: { context.settings.huggingFaceCookieSource },
                        resultValidation: .webProviderCostBalance,
                        sourceModeOverride: .web,
                        context: context),
                ]),
            ProviderSettingsPickerDescriptor(
                id: "huggingface-usage-source",
                title: "Usage source",
                subtitle: "Auto uses the API token when available; Browser cookies shows prepaid Credits.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }
}
