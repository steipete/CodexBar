import CodexBarCore
import Foundation

/// Builder context for provider implementations.
///
/// This is the single "dependency injection" object we pass into providers when building their fetch closures.
/// Keep this small: add shared dependencies here only when at least 2 providers need it.
struct ProviderBuildContext: Sendable {
    let settings: SettingsStore
    let metadata: [UsageProvider: ProviderMetadata]
    let codexFetcher: UsageFetcher
    let claudeFetcher: any ClaudeUsageFetching

    func meta(for provider: UsageProvider) -> ProviderMetadata {
        self.metadata[provider]!
    }
}

/// App-side provider implementation.
///
/// Rules:
/// - Provider implementations return *data/behavior descriptors*; the app owns UI.
/// - Do not mix identity fields across providers (email/org/plan/loginMethod stays siloed).
protocol ProviderImplementation: Sendable {
    var id: UsageProvider { get }
    var style: IconStyle { get }

    func makeFetch(context: ProviderBuildContext) -> @Sendable () async throws -> UsageSnapshot

    /// Optional provider-specific settings toggles to render in the Providers pane.
    ///
    /// Important: Providers must not return custom SwiftUI views here. Only shared toggle/action descriptors.
    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor]

    /// Optional provider-specific settings fields to render in the Providers pane.
    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor]
}

extension ProviderImplementation {
    @MainActor
    func settingsToggles(context _: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
