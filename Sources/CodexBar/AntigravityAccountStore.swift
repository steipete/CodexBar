import CodexBarCore
import Foundation
import Security

protocol AntigravityAccountStoring: Sendable {
    func loadAccounts() throws -> AntigravityAccountStore?
    func storeAccounts(_ accounts: AntigravityAccountStore?) throws
}

struct AntigravityAccountStore: Codable, Sendable {
    let version: Int
    let accounts: [AntigravityAccount]
    let activeIndex: Int
    let activeIndexByFamily: [String: Int]

    struct AntigravityAccount: Codable, Sendable {
        let email: String
        let refreshToken: String
        let projectId: String?
        let addedAt: TimeInterval
        let lastUsed: TimeInterval?
        let rateLimitResetTimes: [String: TimeInterval]
        let coolingDownUntil: TimeInterval?
        let cooldownReason: String?

        var displayName: String {
            email
        }

        var refreshTokenWithProjectId: String {
            if let projectId = projectId, !projectId.isEmpty {
                return "\(refreshToken)|\(projectId)"
            }
            return "\(refreshToken)|"
        }
    }
}

enum AntigravityAccountStoreError: LocalizedError {
    case keychainStatus(OSStatus)
    case invalidData
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case let .keychainStatus(status):
            "Keychain error: \(status)"
        case .invalidData:
            "Keychain returned invalid data."
        case let .decodingFailed(error):
            "Failed to decode account data: \(error.localizedDescription)"
        }
    }
}

struct KeychainAntigravityAccountStore: AntigravityAccountStoring {
    private static let log = CodexBarLog.logger("antigravity-account-store")

    private let service = "com.steipete.CodexBar"
    private let account = "antigravity-accounts"

    func loadAccounts() throws -> AntigravityAccountStore? {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            Self.log.error("Keychain read failed: \(status)")
            throw AntigravityAccountStoreError.keychainStatus(status)
        }

        guard let data = result as? Data else {
            throw AntigravityAccountStoreError.invalidData
        }

        do {
            let decoder = JSONDecoder()
            let accounts = try decoder.decode(AntigravityAccountStore.self, from: data)
            return accounts
        } catch {
            Self.log.error("Failed to decode accounts data: \(error)")
            throw AntigravityAccountStoreError.decodingFailed(error)
        }
    }

    func storeAccounts(_ accounts: AntigravityAccountStore?) throws {
        guard let accounts = accounts else {
            try self.deleteAccountsIfPresent()
            return
        }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(accounts)

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
                throw AntigravityAccountStoreError.keychainStatus(updateStatus)
            }

            var addQuery = query
            for (key, value) in attributes {
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                Self.log.error("Keychain add failed: \(addStatus)")
                throw AntigravityAccountStoreError.keychainStatus(addStatus)
            }
        } catch {
            Self.log.error("Failed to encode accounts data: \(error)")
            throw AntigravityAccountStoreError.decodingFailed(error)
        }
    }

    private func deleteAccountsIfPresent() throws {
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
        throw AntigravityAccountStoreError.keychainStatus(status)
    }
}