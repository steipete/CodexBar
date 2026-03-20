import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct GrokProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .grok

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.grokAPIToken
        _ = settings.grokManagementToken
        _ = settings.grokTeamID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return nil
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if GrokSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if GrokSettingsReader.managementKey(environment: context.environment) != nil {
            return true
        }
        context.settings.ensureGrokAPITokenLoaded()
        let apiToken = context.settings.grokAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let mgmtToken = context.settings.grokManagementToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !apiToken.isEmpty || !mgmtToken.isEmpty
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "grok-api-key",
                title: "API key",
                subtitle: "For key status monitoring. Get your key from console.x.ai.",
                kind: .secure,
                placeholder: "xai-...",
                binding: context.stringBinding(\.grokAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "grok-open-console",
                        title: "Open Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.x.ai") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "grok-management-key",
                title: "Management key",
                subtitle: "For billing/usage tracking. Console > Settings > Management Keys.",
                kind: .secure,
                placeholder: "xai-token-...",
                binding: context.stringBinding(\.grokManagementToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "grok-open-management-keys",
                        title: "Get Key",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.x.ai/settings/management-keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "grok-team-id",
                title: "Team ID",
                subtitle: "Your xAI team identifier. Usually \"default\" for personal accounts.",
                kind: .text,
                placeholder: "default",
                binding: context.stringBinding(\.grokTeamID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
