import AppKit
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
        _ = settings.openAIAPIKey
        _ = settings.openAIAPIProjectID
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OpenAIAPISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                binding: context.stringBinding(\.openAIAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "openai-open-billing",
                        title: "Open billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(
                                string: "https://platform.openai.com/settings/organization/billing/overview")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "openai-project-id",
                title: "Project ID",
                subtitle: "Optional. Applies to the configured Admin API key; selected token accounts do not " +
                    "inherit OPENAI_PROJECT_ID.",
                kind: .plain,
                placeholder: "proj_...",
                binding: context.stringBinding(\.openAIAPIProjectID),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "openai-open-projects",
                        title: "Open projects",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://platform.openai.com/settings/organization/projects") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
