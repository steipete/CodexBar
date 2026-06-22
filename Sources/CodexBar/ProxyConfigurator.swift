import CodexBarCore
import Foundation

/// Bridges the app-level proxy settings into ``ProviderHTTPClient`` so all provider traffic honors them.
@MainActor
enum ProxyConfigurator {
    private static var applied: ProxyConfiguration?
    private static var hasApplied = false

    /// Resolves the configured proxy, or `nil` when disabled / empty / invalid.
    static func resolve(from settings: SettingsStore) -> ProxyConfiguration? {
        guard settings.proxyEnabled else { return nil }
        let trimmed = settings.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? ProxyConfiguration.parse(from: trimmed)
    }

    /// Applies the current settings to the shared HTTP client.
    ///
    /// Safe to call liberally (focus loss, submit, disappear): the session is only rebuilt when the
    /// resolved configuration actually changes.
    static func apply(from settings: SettingsStore) {
        let config = self.resolve(from: settings)
        guard !self.hasApplied || config != self.applied else { return }
        self.applied = config
        self.hasApplied = true
        ProviderHTTPClient.shared.applyProxyConfiguration(config)
    }
}
