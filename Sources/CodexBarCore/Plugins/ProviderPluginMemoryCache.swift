import Foundation

/// JSON-only ephemeral state; validated cookie providers may reuse it across strategy instances.
final class ProviderPluginMemoryCache: @unchecked Sendable {
    static let shared = ProviderPluginMemoryCache()
    private let lock = NSLock()
    private var entries: [String: (json: String, expires: Date)] = [:]

    func get(namespace: String, key: String) -> String? {
        self.lock.withLock {
            let key = namespace + ":" + key
            guard let entry = self.entries[key], entry.expires > Date() else {
                self.entries[key] = nil
                return nil
            }
            return entry.json
        }
    }

    func set(namespace: String, key: String, json: String, ttl: Double) {
        guard key.utf8.count <= 128, json.utf8.count <= 16384, ttl.isFinite, ttl > 0 else { return }
        self.lock.withLock {
            self.entries = self.entries.filter { $0.value.expires > Date() }
            let key = namespace + ":" + key
            guard self.entries[key] != nil || self.entries.count < 128 else { return }
            self.entries[key] = (json, Date().addingTimeInterval(min(ttl, 86400)))
        }
    }
}
