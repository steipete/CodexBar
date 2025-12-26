import AppKit
import CodexBarCore
import Foundation

struct ZaiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .zai
    let style: IconStyle = .zai

    func makeFetch(context: ProviderBuildContext) -> @Sendable () async throws -> UsageSnapshot {
        {
            let fromSettings = await MainActor.run {
                context.settings.zaiAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let apiKey = !fromSettings.isEmpty ? fromSettings : ZaiSettingsReader.apiToken()
            guard let apiKey else {
                throw ZaiSettingsError.missingToken
            }
            let usage = try await ZaiUsageFetcher.fetchUsage(apiKey: apiKey)
            return usage.toUsageSnapshot()
        }
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "zai-api-token",
                title: "API token",
                subtitle: "Stored in Keychain. Paste the token from the z.ai dashboard.",
                kind: .secure,
                placeholder: "Paste token…",
                binding: context.stringBinding(\.zaiAPIToken),
                actions: [],
                isVisible: nil),
        ]
    }
}
