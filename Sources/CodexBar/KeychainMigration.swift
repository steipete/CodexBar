import CodexBarCore
import Foundation
import Security

import LocalAuthentication

/// Migrates keychain items to use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
/// to prevent permission prompts on every rebuild during development.
enum KeychainMigration {
    private static let log = CodexBarLog.logger(LogCategories.keychainMigration)
    private static let migrationKey = "KeychainMigrationV1Completed"
    private static let claudeMigrationKey = "KeychainMigrationClaudeCredentialsV1"


    struct MigrationItem: Hashable, Sendable {
        let service: String
        let account: String?

        var label: String {
            let accountLabel = self.account ?? "<any>"
            return "\(self.service):\(accountLabel)"
        }
    }

    static let itemsToMigrate: [MigrationItem] = [
        MigrationItem(service: "com.steipete.CodexBar", account: "codex-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "claude-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "cursor-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "factory-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "minimax-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "minimax-api-token"),
        MigrationItem(service: "com.steipete.CodexBar", account: "augment-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "copilot-api-token"),
        MigrationItem(service: "com.steipete.CodexBar", account: "zai-api-token"),
        MigrationItem(service: "com.steipete.CodexBar", account: "synthetic-api-key"),
        MigrationItem(service: "Claude Code-credentials", account: nil),
    ]

    /// Run migration once per installation (with a Claude-specific follow-up when credentials change).
    static func migrateIfNeeded() {
        guard !KeychainAccessGate.isDisabled else {
            self.log.info("Keychain access disabled; skipping migration")
            return
        }

        if !UserDefaults.standard.bool(forKey: self.migrationKey) {
            self.log.info("Starting keychain migration to reduce permission prompts")

            var migratedCount = 0
            var errorCount = 0

            for item in self.itemsToMigrate {
                do {
                    if try self.migrateItem(item) {
                        migratedCount += 1
                    }
                } catch {
                    errorCount += 1
                    self.log.error("Failed to migrate \(item.label): \(String(describing: error))")
                }
            }

            self.log.info("Keychain migration complete: \(migratedCount) migrated, \(errorCount) errors")
            UserDefaults.standard.set(true, forKey: self.migrationKey)

            if migratedCount > 0 {
                self.log.info("✅ Future rebuilds will not prompt for keychain access")
            }
        } else {
            self.log.debug("Keychain migration already completed, skipping")
        }

        self.migrateClaudeCredentialsIfNeeded()
    }

    static func migrateClaudeCredentialsIfNeeded() {
        guard let item = self.itemsToMigrate.first(where: { $0.service == "Claude Code-credentials" }) else {
            return
        }
        guard let fingerprint = self.claudeCredentialsFingerprint() else { return }

        let stored = self.loadClaudeMigrationFingerprint()
        if stored == fingerprint { return }

        do {
            if try self.migrateItem(item) {
                self.log.info("Migrated Claude credentials to ThisDeviceOnly")
            } else {
                self.log.debug("Claude credentials already using correct accessibility")
            }
        } catch {
            self.log.error("Failed to migrate Claude credentials: \(String(describing: error))")
            return
        }

        self.saveClaudeMigrationFingerprint(fingerprint)
    }

    /// Migrate a single keychain item to the new accessibility level
    /// Returns true if item was migrated, false if item didn't exist
    private static func migrateItem(_ item: MigrationItem) throws -> Bool {
        // First, try to read the existing item
        var result: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        if let account = item.account {
            query[kSecAttrAccount as String] = account
        }

        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            // Item doesn't exist, nothing to migrate
            return false
        }

        guard status == errSecSuccess else {
            throw KeychainMigrationError.readFailed(status)
        }

        guard let rawItem = result as? [String: Any],
              let data = rawItem[kSecValueData as String] as? Data,
              let accessible = rawItem[kSecAttrAccessible as String] as? String
        else {
            throw KeychainMigrationError.invalidItemFormat
        }

        // Check if already using the correct accessibility
        if accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) {
            self.log.debug("\(item.label) already using correct accessibility")
            return false
        }

        // Delete the old item
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
        ]
        if let account = item.account {
            deleteQuery[kSecAttrAccount as String] = account
        }

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess else {
            throw KeychainMigrationError.deleteFailed(deleteStatus)
        }

        // Add it back with the new accessibility
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let account = item.account {
            addQuery[kSecAttrAccount as String] = account
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainMigrationError.addFailed(addStatus)
        }

        self.log.info("Migrated \(item.label) to new accessibility level")
        return true
    }

    private struct ClaudeCredentialsFingerprint: Codable, Equatable {
        let modifiedAt: Int?
        let accessible: String?
    }

    private static func claudeCredentialsFingerprint() -> ClaudeCredentialsFingerprint? {
        #if os(macOS)
        if KeychainAccessGate.isDisabled { return nil }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            return nil
        }
        let modifiedAt = (attrs[kSecAttrModificationDate as String] as? Date)
            .map { Int($0.timeIntervalSince1970) }
        let accessible = attrs[kSecAttrAccessible as String] as? String
        return ClaudeCredentialsFingerprint(modifiedAt: modifiedAt, accessible: accessible)
        #else
        return nil
        #endif
    }

    private static func loadClaudeMigrationFingerprint() -> ClaudeCredentialsFingerprint? {
        guard let data = UserDefaults.standard.data(forKey: self.claudeMigrationKey) else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentialsFingerprint.self, from: data)
    }

    private static func saveClaudeMigrationFingerprint(_ fingerprint: ClaudeCredentialsFingerprint) {
        guard let data = try? JSONEncoder().encode(fingerprint) else { return }
        UserDefaults.standard.set(data, forKey: self.claudeMigrationKey)
    }

    #if DEBUG
    static func _resetClaudeMigrationTrackingForTesting() {
        UserDefaults.standard.removeObject(forKey: self.claudeMigrationKey)
        UserDefaults.standard.removeObject(forKey: self.migrationKey)
    }
    #endif

    /// Reset migration flag (for testing)
    static func resetMigrationFlag() {
        UserDefaults.standard.removeObject(forKey: self.migrationKey)
    }
}

enum KeychainMigrationError: Error {
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case addFailed(OSStatus)
    case invalidItemFormat
}
