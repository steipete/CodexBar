import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct RovoDevProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .rovodev

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.rovoDevAPIToken
        _ = settings.rovoDevEmail
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        // Available when both email and API token are configured.
        if RovoDevSettingsReader.apiToken(environment: context.environment) != nil,
           RovoDevSettingsReader.email(environment: context.environment) != nil
        {
            return true
        }
        return !context.settings.rovoDevAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !context.settings.rovoDevEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "rovodev-email",
                title: "Atlassian email",
                subtitle: "Your Atlassian account email address.",
                kind: .plain,
                placeholder: "you@example.com",
                binding: context.stringBinding(\.rovoDevEmail),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "rovodev-api-token",
                title: "API token",
                subtitle: "Create a Rovo Dev token with only the read:rovodev:limits scope. " +
                    "Stored in ~/.codexbar/config.json or set ROVODEV_API_TOKEN in your environment.",
                kind: .secure,
                placeholder: "ATATT3x...",
                binding: context.stringBinding(\.rovoDevAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "rovodev-open-token-page",
                        title: "Get API token",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
