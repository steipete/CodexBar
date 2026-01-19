import CodexBarCore
import Foundation
import Security

protocol MiniMaxCookieStoring: Sendable {
    func loadCookieHeader() throws -> String?
    func storeCookieHeader(_ header: String?) throws
}

enum MiniMaxCookieStoreError: LocalizedError {
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

struct KeychainMiniMaxCookieStore: MiniMaxCookieStoring {
    private static let log = CodexBarLog.logger("minimax-cookie-store")

    private let service = "com.steipete.CodexBar"
    private let account = "minimax-cookie"

    func loadCookieHeader() throws -> String? {
        guard !KeychainAccessGate.isDisabled else {
            Self.log.debug("Keychain access disabled; skipping cookie load")
            return nil
        }
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
                kind: .minimaxCookie,
                service: self.service,
                account: self.account))
        }

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            Self.log.error("Keychain read failed: \(status)")
            throw MiniMaxCookieStoreError.keychainStatus(status)
        }

        guard let data = result as? Data else {
            throw MiniMaxCookieStoreError.invalidData
        }
        let header = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let header, !header.isEmpty {
            return header
        }
        return nil
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
            return
        }
        guard MiniMaxCookieHeader.normalized(from: raw) != nil else {
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
            throw MiniMaxCookieStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.log.error("Keychain add failed: \(addStatus)")
            throw MiniMaxCookieStoreError.keychainStatus(addStatus)
        }
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
            return
        }
        Self.log.error("Keychain delete failed: \(status)")
        throw MiniMaxCookieStoreError.keychainStatus(status)
    }
}
