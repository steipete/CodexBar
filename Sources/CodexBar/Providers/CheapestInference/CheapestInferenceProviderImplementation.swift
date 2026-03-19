import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct CheapestInferenceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cheapestinference

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.cheapestInferenceAPIToken
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return nil
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if CheapestInferenceSettingsReader.apiToken(environment: context.environment) != nil {
            return true
        }
        return !context.settings.cheapestInferenceAPIToken
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "cheapestinference-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. "
                    + "Get your key from cheapestinference.com/dashboard.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.cheapestInferenceAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
