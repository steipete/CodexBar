import CodexBarCore
import Foundation

protocol CookieHeaderStoring: Sendable {
    func loadCookieHeader() throws -> String?
    func storeCookieHeader(_ header: String?) throws
}

struct KeychainCookieHeaderStore: CookieHeaderStoring {
    private static let log = CodexBarLog.logger(LogCategories.cookieHeaderStore)

    private let account: String
    private let store: KeychainStringStore

    // Cache to reduce keychain access frequency
    private nonisolated(unsafe) static var cache: [String: CachedValue] = [:]
    private static let cacheLock = NSLock()
    private static let cacheTTL: TimeInterval = 1800 // 30 minutes

    private struct CachedValue {
        let value: String?
        let timestamp: Date

        var isExpired: Bool {
            Date().timeIntervalSince(self.timestamp) > KeychainCookieHeaderStore.cacheTTL
        }
    }

    init(account: String, promptKind: KeychainPromptContext.Kind) {
        self.account = account
        self.store = KeychainStringStore(
            account: account,
            promptKind: promptKind,
            logCategory: LogCategories.cookieHeaderStore)
    }

    func loadCookieHeader() throws -> String? {
        guard !KeychainAccessGate.isDisabled else {
            Self.log.debug("Keychain access disabled; skipping cookie load")
            return nil
        }
        // Check cache first
        Self.cacheLock.lock()
        if let cached = Self.cache[self.account], !cached.isExpired {
            Self.cacheLock.unlock()
            Self.log.debug("Using cached cookie header for \(self.account)")
            return cached.value
        }
        Self.cacheLock.unlock()
        let finalValue = try self.store.load()
        guard !KeychainAccessGate.isDisabled else { return nil }

        // Cache the result
        Self.cacheLock.lock()
        Self.cache[self.account] = CachedValue(value: finalValue, timestamp: Date())
        Self.cacheLock.unlock()

        return finalValue
    }

    func storeCookieHeader(_ header: String?) throws {
        guard !KeychainAccessGate.isDisabled else {
            Self.log.debug("Keychain access disabled; skipping cookie store")
            return
        }
        guard try self.store.store(header, isValid: { CookieHeaderNormalizer.normalize($0) != nil }) else { return }
        let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.cacheLock.withLock {
            if let raw, !raw.isEmpty, CookieHeaderNormalizer.normalize(raw) != nil {
                Self.cache[self.account] = CachedValue(value: raw, timestamp: Date())
            } else {
                Self.cache.removeValue(forKey: self.account)
            }
        }
    }
}
