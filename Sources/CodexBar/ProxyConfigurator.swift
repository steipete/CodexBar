import CodexBarCore
import Foundation

/// Bridges the app-level proxy settings into ``ProviderHTTPClient`` so all provider traffic honors them.
@MainActor
enum ProxyConfigurator {
    /// Resolves the configured proxy, or `nil` when disabled / empty / invalid.
    static func resolve(from settings: SettingsStore) -> ProxyConfiguration? {
        guard settings.proxyEnabled else { return nil }
        let trimmed = settings.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? ProxyConfiguration.parse(from: trimmed)
    }

    /// Applies the current settings to the shared HTTP client.
    static func apply(from settings: SettingsStore) {
        ProviderHTTPClient.shared.applyProxyConfiguration(self.resolve(from: settings))
    }
}
