import Foundation

/// One browser profile's value for a declared local-storage key.
public struct ProviderPluginLocalStorageEntry: Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }

    func json() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["id": self.id, "label": self.label, "value": self.value])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProviderPluginError.secretAccess("local storage encoding failed")
        }
        return json
    }

    static func json(_ entries: [Self]) throws -> String {
        try "[" + entries.map { try $0.json() }.joined(separator: ",") + "]"
    }
}

extension ProviderPluginContextOptions {
    /// Shared by both engines: checks the manifest grant and the source gate, reads the entries, and redacts them.
    func readLocalStorage(
        manifest: ProviderPluginManifest,
        origin: String,
        key: String,
        redactionValues: ProviderPluginRedactionValues) async throws -> String
    {
        let grant = try manifest.localStorageKey(origin: origin, key: key)
        guard self.cookieSource == .auto, let resolver = self.localStorageResolver else {
            throw ProviderPluginError.secretAccess("browser local storage is unavailable")
        }
        let entries = try await resolver(grant.origin, grant.key)
        for entry in entries {
            redactionValues.insert(entry.value)
        }
        return try ProviderPluginLocalStorageEntry.json(entries)
    }
}

enum ProviderPluginLocalStorage {
    /// Reads the declared key from every Chromium profile that holds the origin, in the shared default browser
    /// order. Chromium local storage is not encrypted, so no Keychain access is involved. Other platforms and
    /// browsers expose nothing.
    static func resolver(browserDetection: BrowserDetection) -> ProviderPluginRuntime.LocalStorageResolver? {
        #if os(macOS)
        return { origin, key in
            BrowserLocalStorageAPI.live.profiles(
                for: origin,
                browsers: ChromiumLocalStorageDiscovery.defaultBrowsers,
                using: browserDetection,
                logger: { _ in })
                .compactMap { profile in
                    profile.entries.first { $0.key == key }
                        .map { ProviderPluginLocalStorageEntry(id: profile.id, label: profile.label, value: $0.value) }
                }
        }
        #else
        _ = browserDetection
        return nil
        #endif
    }
}
