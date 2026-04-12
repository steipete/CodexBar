import CodexBarCore
import Foundation

protocol NetworkProxyPasswordStoring: Sendable {
    func loadPassword() throws -> String?
    func storePassword(_ password: String?) throws
}

enum NetworkProxyPasswordStoreError: LocalizedError {
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable:
            "Network proxy password store is unavailable."
        }
    }
}

struct KeychainNetworkProxyPasswordStore: NetworkProxyPasswordStoring {
    private static let key = KeychainCacheStore.Key(
        category: "network-proxy",
        identifier: "password")

    func loadPassword() throws -> String? {
        switch KeychainCacheStore.load(key: Self.key, as: String.self) {
        case let .found(value):
            value
        case .missing:
            nil
        case .invalid:
            throw NetworkProxyPasswordStoreError.keychainUnavailable
        }
    }

    func storePassword(_ password: String?) throws {
        if let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainCacheStore.store(key: Self.key, entry: password)
        } else {
            KeychainCacheStore.clear(key: Self.key)
        }
    }
}
