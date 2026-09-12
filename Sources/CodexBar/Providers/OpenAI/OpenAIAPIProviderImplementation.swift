import CodexBarCore
import Foundation

struct OpenAIAPIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .openai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .openai, field: .apiKey]
        _ = settings[providerConfig: .openai, field: .secretWorkspace(logField: "projectID")]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OpenAIAPISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .openai, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "openai-api-key",
                title: "Admin API key",
                subtitle: "Stored in ~/.codexbar/config.json. OPENAI_ADMIN_KEY is required for organization usage; " +
                    "legacy/user keys only get a best-effort balance fallback.",
                kind: .secure,
                placeholder: "sk-admin-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "openai-open-billing",
                        title: "Open billing",
                        url: URL(string: "https://platform.openai.com/settings/organization/billing/overview")),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "openai-project-id",
                title: "Project ID",
                subtitle: "Optional. Applies to the configured Admin API key; selected token accounts do not " +
                    "inherit OPENAI_PROJECT_ID.",
                kind: .plain,
                placeholder: "proj_...",
                binding: context.providerConfigBinding(.secretWorkspace(logField: "projectID")),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "openai-open-projects",
                        title: "Open projects",
                        url: URL(string: "https://platform.openai.com/settings/organization/projects")),
                ],
                isVisible: nil),
        ]
    }
}
