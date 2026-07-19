import CodexBarCore

/// Source of truth for app-side provider implementations.
///
/// Keep provider registration centralized here. The rest of the app should *not* have to be updated when a new
/// provider is added, aside from enum/metadata work in `CodexBarCore`.
enum ProviderCatalog {
    /// All provider implementations shipped in the app.
    static let all: [any ProviderImplementation] = ProviderImplementationRegistry.all

    /// Lookup for a single provider implementation.
    static func implementation(for id: UsageProvider) -> (any ProviderImplementation)? {
        ProviderImplementationRegistry.implementation(for: id)
    }
}
