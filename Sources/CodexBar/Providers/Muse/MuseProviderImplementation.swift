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
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MuseSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings.museAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // A rejected MUSE_BASE_URL must still reach the fetch path so the override error is visible.
        if MuseSettingsReader.hasBaseURLOverride(environment: context.environment) {
            return true
        }
        return MuseLocalAuthReader.read() != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "muse-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Create a key at https://dev.meta.ai, or run `muse login`.",
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
                onActivate: nil),
        ]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }
}
