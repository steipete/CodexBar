import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct DeepgramProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .deepgram

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.deepgramAPIToken
        _ = settings.deepgramProjectID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return nil
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        let envToken = DeepGramSettingsReader.apiToken(environment: context.environment)
        let envProjectID = DeepGramSettingsReader.projectID(environment: context.environment)

        if envToken != nil, envProjectID != nil {
            return true
        }

        let token = context.settings.deepgramAPIToken
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let projectID = context.settings.deepgramProjectID
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return !token.isEmpty && !projectID.isEmpty
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        return [
            ProviderSettingsFieldDescriptor(
                id: "deepgram-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. "
                    + "Get your key from the Deepgram console and set a key spending limit "
                    + "there to enable API key quota tracking.",
                kind: .secure,
                placeholder: "dg_...",
                binding: context.stringBinding(\.deepgramAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: nil),

            ProviderSettingsFieldDescriptor(
                id: "deepgram-project-id",
                title: "Project ID",
                subtitle: "Project ID used for usage breakdowns. Get it from the Deepgram console.",
                kind: .plain,
                placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
                binding: context.stringBinding(\.deepgramProjectID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}

