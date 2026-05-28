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
        _ = settings.bedrockAuthMode
        _ = settings.bedrockProfile
        _ = settings.bedrockAccessKeyID
        _ = settings.bedrockSecretAccessKey
        _ = settings.bedrockRegion
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        BedrockSettingsReader.hasCredentials(environment: context.environment)
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let binding = Binding(
            get: { context.settings.bedrockAuthMode },
            set: { context.settings.bedrockAuthMode = $0 })
        let options = [
            ProviderSettingsPickerOption(id: BedrockAuthMode.keys.rawValue, title: "Access keys"),
            ProviderSettingsPickerOption(id: BedrockAuthMode.profile.rawValue, title: "AWS profile"),
        ]
        return [
            ProviderSettingsPickerDescriptor(
                id: "bedrock-auth-mode",
                title: "Authentication",
                subtitle: "Use static access keys, or resolve credentials from a named AWS profile "
                    + "(supports SSO and assume-role via the AWS CLI).",
                binding: binding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let isKeysMode = { context.settings.bedrockAuthMode != BedrockAuthMode.profile.rawValue }
        let isProfileMode = { context.settings.bedrockAuthMode == BedrockAuthMode.profile.rawValue }
        return [
            ProviderSettingsFieldDescriptor(
                id: "bedrock-profile",
                title: "Profile name",
                subtitle: "Named AWS profile from ~/.aws/config. Can also be set with AWS_PROFILE.",
                kind: .plain,
                placeholder: "default",
                binding: context.stringBinding(\.bedrockProfile),
                actions: [],
                isVisible: isProfileMode,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "bedrock-access-key-id",
                title: "Access key ID",
                subtitle: "AWS access key ID. Can also be set with AWS_ACCESS_KEY_ID.",
                kind: .secure,
                placeholder: "AKIA...",
                binding: context.stringBinding(\.bedrockAccessKeyID),
                actions: [],
                isVisible: isKeysMode,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "bedrock-secret-access-key",
                title: "Secret access key",
                subtitle: "AWS secret access key. Can also be set with AWS_SECRET_ACCESS_KEY.",
                kind: .secure,
                placeholder: "",
                binding: context.stringBinding(\.bedrockSecretAccessKey),
                actions: [],
                isVisible: isKeysMode,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "bedrock-region",
                title: "Region",
                subtitle: "AWS region. Can also be set with AWS_REGION. "
                    + "In profile mode, leave blank to use the profile's region.",
                kind: .plain,
                placeholder: "us-east-1",
                binding: context.stringBinding(\.bedrockRegion),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
