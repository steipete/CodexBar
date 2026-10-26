import CodexBarCore
import Foundation

protocol ZaiTokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

struct KeychainZaiTokenStore: ZaiTokenStoring {
    private static let log = CodexBarLog.logger(LogCategories.provider(.zai, scope: "token-store"))

    /// Provider-specific by design: this adapter owns z.ai's legacy credential item and logging category.
    private let store = KeychainStringStore(
        account: "zai-api-token",
        promptKind: .zaiToken,
        logCategory: LogCategories.provider(.zai, scope: "token-store"))

    // Cache to reduce keychain access frequency
    private nonisolated(unsafe) static var cachedToken: String?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private static let cacheLock = NSLock()
    private static let cacheTTL: TimeInterval = 1800 // 30 minutes

    func loadToken() throws -> String? {
        guard !KeychainAccessGate.isDisabled else {
            Self.log.debug("Keychain access disabled; skipping token load")
            return nil
        }
        // Check cache first
        Self.cacheLock.lock()
        if let timestamp = Self.cacheTimestamp,
           Date().timeIntervalSince(timestamp) < Self.cacheTTL
        {
            let cached = Self.cachedToken
            Self.cacheLock.unlock()
            Self.log.debug("Using cached Zai token")
            return cached
        }
        Self.cacheLock.unlock()
        let finalValue = try self.store.load()
        guard !KeychainAccessGate.isDisabled else { return nil }

        // Cache the result
        Self.cacheLock.lock()
        Self.cachedToken = finalValue
        Self.cacheTimestamp = Date()
        Self.cacheLock.unlock()

        return finalValue
    }

    func storeToken(_ token: String?) throws {
        guard !KeychainAccessGate.isDisabled else {
            Self.log.debug("Keychain access disabled; skipping token store")
            return
        }
        guard try self.store.store(token) else { return }
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalValue = cleaned?.isEmpty == false ? cleaned : nil
        Self.cacheLock.withLock {
            Self.cachedToken = finalValue
            Self.cacheTimestamp = finalValue == nil ? nil : Date()
        }
    }
}
