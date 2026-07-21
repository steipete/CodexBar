import CodexBarCore
import Foundation

struct HyperProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .hyper

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.hyperAPIKey
        _ = settings.tokenAccountsData(for: .hyper)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if HyperSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings.hyperAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !context.settings.tokenAccounts(for: .hyper).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "hyper-api-key",
                title: "API key",
                subtitle: "Stored in the CodexBar config file. Generate a key from the Charm Hyper dashboard.",
                kind: .secure,
                placeholder: "hk-...",
                binding: context.stringBinding(\.hyperAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
