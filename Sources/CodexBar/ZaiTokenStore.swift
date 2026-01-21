import CodexBarCore
import Foundation
import Security

protocol ZaiTokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

enum ZaiTokenStoreError: LocalizedError {
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

struct KeychainZaiTokenStore: ZaiTokenStoring {
    private static let log = CodexBarLog.logger(LogCategories.zaiTokenStore)

    private let service = "com.steipete.CodexBar"
    private let account = "zai-api-token"

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
                kind: .zaiToken,
                service: self.service,
                account: self.account))
        }

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            // Cache the nil result
            Self.cacheLock.lock()
            Self.cachedToken = nil
            Self.cacheTimestamp = Date()
            Self.cacheLock.unlock()
            return nil
        }
        guard status == errSecSuccess else {
            Self.log.error("Keychain read failed: \(status)")
            throw ZaiTokenStoreError.keychainStatus(status)
        }

        guard let data = result as? Data else {
            throw ZaiTokenStoreError.invalidData
        }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalValue = (token?.isEmpty == false) ? token : nil

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
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == nil || cleaned?.isEmpty == true {
            try self.deleteTokenIfPresent()
            // Invalidate cache
            Self.cacheLock.lock()
            Self.cachedToken = nil
            Self.cacheTimestamp = nil
            Self.cacheLock.unlock()
            return
        }

        let data = cleaned!.data(using: .utf8)!
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
            Self.cachedToken = cleaned
            Self.cacheTimestamp = Date()
            Self.cacheLock.unlock()
            return
        }
        if updateStatus != errSecItemNotFound {
            Self.log.error("Keychain update failed: \(updateStatus)")
            throw ZaiTokenStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.log.error("Keychain add failed: \(addStatus)")
            throw ZaiTokenStoreError.keychainStatus(addStatus)
        }

        // Update cache
        Self.cacheLock.lock()
        Self.cachedToken = cleaned
        Self.cacheTimestamp = Date()
        Self.cacheLock.unlock()
    }

    private func deleteTokenIfPresent() throws {
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
            Self.cachedToken = nil
            Self.cacheTimestamp = nil
            Self.cacheLock.unlock()
            return
        }
        Self.log.error("Keychain delete failed: \(status)")
        throw ZaiTokenStoreError.keychainStatus(status)
    }
}
