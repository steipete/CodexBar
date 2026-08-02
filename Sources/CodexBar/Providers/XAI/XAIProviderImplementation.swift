import CodexBarCore
import Foundation

struct XAIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .xai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.xaiManagementAPIKey
        _ = settings.xaiTeamID
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if XAISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.xaiManagementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                binding: context.stringBinding(\.xaiManagementAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "xai-team-id",
                title: "Team ID",
                subtitle: "Required. Shown in the xAI Console URL and team settings.",
                kind: .plain,
                placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
                binding: context.stringBinding(\.xaiTeamID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
