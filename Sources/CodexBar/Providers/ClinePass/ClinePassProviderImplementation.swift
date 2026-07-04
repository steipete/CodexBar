import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct ClinePassProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .clinepass

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.clinePassAPIToken
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return nil
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if ClinePassSettingsReader.apiToken(environment: context.environment) != nil {
            return true
        }
        return !context.settings.clinePassAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "clinepass-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. "
                    + "Create a key at app.cline.bot under Settings → API Keys. "
                    + "Shows your ClinePass 5-hour, weekly, and monthly usage limits.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.clinePassAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
