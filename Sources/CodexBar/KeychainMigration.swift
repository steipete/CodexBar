import CodexBarCore
import Foundation
import Security

/// Migrates keychain items from the legacy login keychain to the Data Protection
/// keychain so that access is validated by team ID rather than binary hash.
///
/// V1 changed the accessibility level (still legacy keychain).
/// V2 moves items into the Data Protection keychain with a team-scoped access
/// group, eliminating permission prompts after Sparkle binary updates.
enum KeychainMigration {
    private static let log = CodexBarLog.logger(LogCategories.keychainMigration)
    private static let migrationKey = "KeychainMigrationV1Completed"
    private static let migrationV2Key = "KeychainMigrationV2DPCompleted"

    struct MigrationItem: Hashable {
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
    ]

    /// Run migration once per installation
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

    // MARK: - V2: Legacy → Data Protection keychain

    /// Move items from the legacy login keychain into the Data Protection
    /// keychain. This is the migration that actually fixes the repeated-prompt
    /// problem: the DP keychain validates by team ID, not binary hash.
    static func migrateToDataProtectionIfNeeded() {
        guard !KeychainAccessGate.isDisabled else {
            self.log.info("Keychain access disabled; skipping DP migration")
            return
        }

        guard !UserDefaults.standard.bool(forKey: self.migrationV2Key) else {
            self.log.debug("Data Protection keychain migration already completed, skipping")
            return
        }

        self.log.info("Starting Data Protection keychain migration")

        var migratedCount = 0
        var errorCount = 0

        for item in self.itemsToMigrate {
            do {
                if try self.migrateItemToDP(item) {
                    migratedCount += 1
                }
            } catch {
                errorCount += 1
                self.log.error("DP migration failed for \(item.label): \(String(describing: error))")
            }
        }

        self.log.info("DP migration complete: \(migratedCount) migrated, \(errorCount) errors")
        UserDefaults.standard.set(true, forKey: self.migrationV2Key)
    }

    /// Read an item from the legacy keychain and write it to the Data
    /// Protection keychain, then remove the legacy copy.
    private static func migrateItemToDP(_ item: MigrationItem) throws -> Bool {
        // Check if already present in DP keychain
        var dpCheckQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        DataProtectionKeychain.apply(to: &dpCheckQuery)
        if let account = item.account {
            dpCheckQuery[kSecAttrAccount as String] = account
        }
        if SecItemCopyMatching(dpCheckQuery as CFDictionary, nil) == errSecSuccess {
            self.log.debug("\(item.label) already in DP keychain")
            return false
        }

        // Read from legacy keychain
        var legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let account = item.account {
            legacyQuery[kSecAttrAccount as String] = account
        }

        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
        if readStatus == errSecItemNotFound {
            return false
        }
        guard readStatus == errSecSuccess,
              let data = result as? Data
        else {
            throw KeychainMigrationError.readFailed(readStatus)
        }

        // Write to DP keychain
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        DataProtectionKeychain.apply(to: &addQuery)
        if let account = item.account {
            addQuery[kSecAttrAccount as String] = account
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainMigrationError.addFailed(addStatus)
        }

        // Remove legacy copy
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
        ]
        if let account = item.account {
            deleteQuery[kSecAttrAccount as String] = account
        }
        SecItemDelete(deleteQuery as CFDictionary)

        self.log.info("Migrated \(item.label) to Data Protection keychain")
        return true
    }

    /// Reset migration flag (for testing)
    static func resetMigrationFlag() {
        UserDefaults.standard.removeObject(forKey: self.migrationKey)
    }

    /// Reset V2 migration flag (for testing)
    static func resetMigrationV2Flag() {
        UserDefaults.standard.removeObject(forKey: self.migrationV2Key)
    }
}

enum KeychainMigrationError: Error {
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case addFailed(OSStatus)
    case invalidItemFormat
}
