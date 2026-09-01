import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct MuseProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .muse

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.museAPIToken
        _ = settings.museBaseURL
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MuseSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if BinaryLocator.resolveMuseBinary() != nil {
            return true
        }
        context.settings.ensureMuseAPITokenLoaded()
        return !context.settings.museAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "muse-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Paste META_API_KEY from https://dev.meta.ai or run `muse login`.",
                kind: .secure,
                placeholder: "Paste META_API_KEY…",
                binding: context.stringBinding(\.museAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "muse-open-dev",
                        title: "Open dev.meta.ai",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://dev.meta.ai") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMuseAPITokenLoaded() }),
        ]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }
}
