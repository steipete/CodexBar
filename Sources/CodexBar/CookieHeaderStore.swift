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
    private static let log = CodexBarLog.logger("cookie-header-store")

    private let service = "com.steipete.CodexBar"
    private let account: String
    private let promptKind: KeychainPromptContext.Kind

    init(account: String, promptKind: KeychainPromptContext.Kind) {
        self.account = account
        self.promptKind = promptKind
    }

    func loadCookieHeader() throws -> String? {
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
        if let header, !header.isEmpty {
            return header
        }
        return nil
    }

    func storeCookieHeader(_ header: String?) throws {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            try self.deleteIfPresent()
            return
        }
        guard CookieHeaderNormalizer.normalize(raw) != nil else {
            try self.deleteIfPresent()
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
    }

    private func deleteIfPresent() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        Self.log.error("Keychain delete failed: \(status)")
        throw CookieHeaderStoreError.keychainStatus(status)
    }
}
