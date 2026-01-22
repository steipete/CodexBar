import CodexBarCore
import Foundation
import Security

protocol CookieHeaderStoring: Sendable {
    func loadCookieHeader() throws -> String?
    func storeCookieHeader(_ header: String?) throws
}

enum CookieHeaderStoreError: LocalizedError {
    case keychainStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .keychainStatus(status):
            "Keychain error: \(status)"
        case .invalidData:
            "Keychain returned invalid data."
        }
    }
}

struct KeychainCookieHeaderStore: CookieHeaderStoring {
    private static let log = CodexBarLog.logger(LogCategories.cookieHeaderStore)

    private let service = "com.steipete.CodexBar"
    private let account: String
    private let promptKind: KeychainPromptContext.Kind

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
        self.promptKind = promptKind
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
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        if case .interactionRequired = KeychainAccessPreflight
            .checkGenericPassword(service: self.service, account: self.account)
        {
            KeychainPromptHandler.handler?(KeychainPromptContext(
                kind: self.promptKind,
                service: self.service,
                account: self.account))
        }

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            // Cache the nil result
            Self.cacheLock.lock()
            Self.cache[self.account] = CachedValue(value: nil, timestamp: Date())
            Self.cacheLock.unlock()
            return nil
        }
        guard status == errSecSuccess else {
            Self.log.error("Keychain read failed: \(status)")
            throw CookieHeaderStoreError.keychainStatus(status)
        }

        guard let data = result as? Data else {
            throw CookieHeaderStoreError.invalidData
        }
        let header = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalValue = (header?.isEmpty == false) ? header : nil

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
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            try self.deleteIfPresent()
            // Invalidate cache
            Self.cacheLock.lock()
            Self.cache.removeValue(forKey: self.account)
            Self.cacheLock.unlock()
            return
        }
        guard CookieHeaderNormalizer.normalize(raw) != nil else {
            try self.deleteIfPresent()
            // Invalidate cache
            Self.cacheLock.lock()
            Self.cache.removeValue(forKey: self.account)
            Self.cacheLock.unlock()
            return
        }

        let data = raw.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            // Update cache
            Self.cacheLock.lock()
            Self.cache[self.account] = CachedValue(value: raw, timestamp: Date())
            Self.cacheLock.unlock()
            return
        }
        if updateStatus != errSecItemNotFound {
            Self.log.error("Keychain update failed: \(updateStatus)")
            throw CookieHeaderStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.log.error("Keychain add failed: \(addStatus)")
            throw CookieHeaderStoreError.keychainStatus(addStatus)
        }

        // Update cache
        Self.cacheLock.lock()
        Self.cache[self.account] = CachedValue(value: raw, timestamp: Date())
        Self.cacheLock.unlock()
    }

    private func deleteIfPresent() throws {
        guard !KeychainAccessGate.isDisabled else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            // Invalidate cache
            Self.cacheLock.lock()
            Self.cache.removeValue(forKey: self.account)
            Self.cacheLock.unlock()
            return
        }
        Self.log.error("Keychain delete failed: \(status)")
        throw CookieHeaderStoreError.keychainStatus(status)
    }
}
