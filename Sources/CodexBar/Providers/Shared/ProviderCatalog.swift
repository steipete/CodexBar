import CodexBarCore

/// Source of truth for app-side provider implementations.
///
/// Keep provider registration centralized here. The rest of the app should *not* have to be updated when a new
/// provider is added, aside from enum/metadata work in `CodexBarCore`.
enum ProviderCatalog {
    /// All provider implementations shipped in the app.
    static let all: [any ProviderImplementation] = [
        CodexProviderImplementation(),
        ClaudeProviderImplementation(),
        ZaiProviderImplementation(),
        CursorProviderImplementation(),
        GeminiProviderImplementation(),
        AntigravityProviderImplementation(),
        FactoryProviderImplementation(),
    ]

    /// Lookup for a single provider implementation.
    static func implementation(for id: UsageProvider) -> (any ProviderImplementation)? {
        self.implementationsByID[id]
    }

    private static let implementationsByID: [UsageProvider: any ProviderImplementation] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })
}
