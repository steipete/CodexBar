import Foundation
import OSLog
import Security

/// Migrates keychain items to use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
/// to prevent permission prompts on every rebuild during development.
enum KeychainMigration {
    private static let log = Logger(subsystem: "com.steipete.codexbar", category: "KeychainMigration")
    private static let migrationKey = "KeychainMigrationV1Completed"

    /// Run migration once per installation
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: self.migrationKey) else {
            self.log.debug("Keychain migration already completed, skipping")
            return
        }

        self.log.notice("Starting keychain migration to reduce permission prompts")

        let itemsToMigrate: [(service: String, account: String)] = [
            ("com.steipete.codexbar.claude-cookie", "default"),
            ("com.steipete.codexbar.codex-cookie", "default"),
            ("com.steipete.codexbar.minimax-cookie", "default"),
            ("com.steipete.codexbar.copilot-token", "default"),
            ("com.steipete.codexbar.zai-token", "default"),
        ]

        var migratedCount = 0
        var errorCount = 0

        for item in itemsToMigrate {
            do {
                if try self.migrateItem(service: item.service, account: item.account) {
                    migratedCount += 1
                }
            } catch {
                errorCount += 1
                self.log.error("Failed to migrate \(item.service): \(String(describing: error))")
            }
        }

        self.log.notice("Keychain migration complete: \(migratedCount) migrated, \(errorCount) errors")
        UserDefaults.standard.set(true, forKey: self.migrationKey)

        if migratedCount > 0 {
            self.log.notice("✅ Future rebuilds will not prompt for keychain access")
        }
    }

    /// Migrate a single keychain item to the new accessibility level
    /// Returns true if item was migrated, false if item didn't exist
    private static func migrateItem(service: String, account: String) throws -> Bool {
        // First, try to read the existing item
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            // Item doesn't exist, nothing to migrate
            return false
        }

        guard status == errSecSuccess else {
            throw KeychainMigrationError.readFailed(status)
        }

        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let accessible = item[kSecAttrAccessible as String] as? String
        else {
            throw KeychainMigrationError.invalidItemFormat
        }

        // Check if already using the correct accessibility
        if accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) {
            self.log.debug("\(service) already using correct accessibility")
            return false
        }

        // Delete the old item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess else {
            throw KeychainMigrationError.deleteFailed(deleteStatus)
        }

        // Add it back with the new accessibility
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainMigrationError.addFailed(addStatus)
        }

        self.log.info("Migrated \(service) to new accessibility level")
        return true
    }

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

