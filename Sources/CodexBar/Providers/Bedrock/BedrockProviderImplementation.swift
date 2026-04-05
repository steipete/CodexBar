import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct BedrockProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .bedrock

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.bedrockAccessKeyID
        _ = settings.bedrockSecretAccessKey
        _ = settings.bedrockRegion
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return nil
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if BedrockSettingsReader.hasCredentials(environment: context.environment) {
            return true
        }
        return !context.settings.bedrockAccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "bedrock-access-key-id",
                title: "Access key ID",
                subtitle: "AWS access key ID. Can also be set via AWS_ACCESS_KEY_ID environment variable.",
                kind: .secure,
                placeholder: "AKIA...",
                binding: context.stringBinding(\.bedrockAccessKeyID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "bedrock-secret-access-key",
                title: "Secret access key",
                subtitle: "AWS secret access key. Can also be set via AWS_SECRET_ACCESS_KEY environment variable.",
                kind: .secure,
                placeholder: "",
                binding: context.stringBinding(\.bedrockSecretAccessKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "bedrock-region",
                title: "Region",
                subtitle: "AWS region (e.g. us-east-1). Can also be set via AWS_REGION environment variable.",
                kind: .plain,
                placeholder: "us-east-1",
                binding: context.stringBinding(\.bedrockRegion),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
