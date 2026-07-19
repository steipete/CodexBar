import CodexBarCore
import Foundation

struct NeuralWattProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .neuralwatt

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.neuralWattAPIKey
        _ = settings.tokenAccountsData(for: .neuralwatt)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if NeuralWattSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings.neuralWattAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !context.settings.tokenAccounts(for: .neuralwatt).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "neuralwatt-api-key",
                title: "API key",
                subtitle: "Stored in the CodexBar config file. Manage keys from the Neuralwatt dashboard.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.neuralWattAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
