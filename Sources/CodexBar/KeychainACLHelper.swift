import CodexBarCore
import Foundation
import Security

/// Helper to manage keychain ACLs and reduce repeated permission prompts.
///
/// The core issue: macOS prompts for keychain access every time an app accesses
/// a keychain item unless that app is in the item's "Always allow" list.
///
/// This helper provides:
/// 1. Creating keychain items with CodexBar already in the trusted apps list
/// 2. Updating existing items to add CodexBar to the trusted list (after user approval)
enum KeychainACLHelper {
    private static let log = CodexBarLog.logger(LogCategories.keychainACL)
    
    /// Error types for ACL operations
    enum ACLError: LocalizedError {
        case accessCopyFailed(OSStatus)
        case aclListCopyFailed(OSStatus)
        case aclContentsCopyFailed(OSStatus)
        case aclSetContentsFailed(OSStatus)
        case noACLFound
        case appPathNotFound
        case trustedAppCreationFailed(OSStatus)
        case accessModificationFailed(OSStatus)
        
        var errorDescription: String? {
            switch self {
            case .accessCopyFailed(let status):
                return "Failed to copy keychain access: \(status)"
            case .aclListCopyFailed(let status):
                return "Failed to copy ACL list: \(status)"
            case .aclContentsCopyFailed(let status):
                return "Failed to copy ACL contents: \(status)"
            case .aclSetContentsFailed(let status):
                return "Failed to set ACL contents: \(status)"
            case .noACLFound:
                return "No ACL found for keychain item"
            case .appPathNotFound:
                return "Could not determine app bundle path"
            case .trustedAppCreationFailed(let status):
                return "Failed to create trusted app reference: \(status)"
            case .accessModificationFailed(let status):
                return "Failed to modify access: \(status)"
            }
        }
    }
    
    /// Get the path to the current app bundle
    private static var appPath: String? {
        Bundle.main.bundlePath
    }
    
    /// Create a SecAccess that includes CodexBar in the trusted apps list.
    /// Items created with this access won't prompt for CodexBar.
    static func createAccessWithCodexBarTrusted(description: String) throws -> SecAccess {
        guard let appPath = self.appPath else {
            throw ACLError.appPathNotFound
        }
        
        var trustedApp: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(appPath, &trustedApp)
        guard trustedStatus == errSecSuccess, let app = trustedApp else {
            throw ACLError.trustedAppCreationFailed(trustedStatus)
        }
        
        var access: SecAccess?
        let accessStatus = SecAccessCreate(description as CFString, [app] as CFArray, &access)
        guard accessStatus == errSecSuccess, let createdAccess = access else {
            throw ACLError.accessCopyFailed(accessStatus)
        }
        
        return createdAccess
    }
    
    /// Add a generic password to keychain with CodexBar pre-authorized.
    /// This prevents future prompts for this item.
    static func addGenericPasswordWithTrustedAccess(
        service: String,
        account: String,
        data: Data,
        label: String? = nil
    ) throws {
        let access = try self.createAccessWithCodexBarTrusted(
            description: label ?? "\(service):\(account)"
        )
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess as String: access,
        ]
        
        if let label = label {
            query[kSecAttrLabel as String] = label
        }
        
        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            self.log.error("Failed to add keychain item with trusted access: \(status)")
            throw ACLError.accessModificationFailed(status)
        }
        
        self.log.info("Added keychain item with CodexBar trusted: \(service):\(account)")
    }
    
    /// Update an existing keychain item to add CodexBar to the trusted apps list.
    /// This requires reading the item first (which may prompt), then rewriting it.
    ///
    /// Note: This only works for items that CodexBar has write access to.
    /// External items (like "Chrome Safe Storage") cannot be modified this way.
    static func addCodexBarToTrustedApps(
        service: String,
        account: String
    ) throws {
        // First, read the existing item (this may prompt the user)
        var result: CFTypeRef?
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess else {
            self.log.error("Failed to read keychain item for ACL update: \(readStatus)")
            throw ACLError.accessCopyFailed(readStatus)
        }
        
        guard let itemDict = result as? [String: Any],
              let itemData = itemDict[kSecValueData as String] as? Data
        else {
            throw ACLError.noACLFound
        }
        
        // Rewrite the item with CodexBar in the trusted list
        try self.addGenericPasswordWithTrustedAccess(
            service: service,
            account: account,
            data: itemData,
            label: itemDict[kSecAttrLabel as String] as? String
        )
        
        self.log.info("Updated keychain item ACL to trust CodexBar: \(service):\(account)")
    }
    
    /// Migrate all CodexBar-owned keychain items to use trusted access.
    /// Call this once after the user grants initial access.
    static func migrateCodexBarItemsToTrustedAccess() {
        let items: [(service: String, account: String)] = [
            ("com.steipete.CodexBar", "codex-cookie"),
            ("com.steipete.CodexBar", "claude-cookie"),
            ("com.steipete.CodexBar", "cursor-cookie"),
            ("com.steipete.CodexBar", "factory-cookie"),
            ("com.steipete.CodexBar", "minimax-cookie"),
            ("com.steipete.CodexBar", "minimax-api-token"),
            ("com.steipete.CodexBar", "augment-cookie"),
            ("com.steipete.CodexBar", "amp-cookie"),
            ("com.steipete.CodexBar", "copilot-api-token"),
            ("com.steipete.CodexBar", "zai-api-token"),
            ("com.steipete.CodexBar", "synthetic-api-key"),
            ("com.steipete.CodexBar", "kimi-auth-token"),
            ("com.steipete.CodexBar", "kimi-k2-api-key"),
        ]
        
        var migratedCount = 0
        var errorCount = 0
        
        for item in items {
            do {
                try self.addCodexBarToTrustedApps(service: item.service, account: item.account)
                migratedCount += 1
            } catch {
                // Item might not exist, which is fine
                if case ACLError.accessCopyFailed(let status) = error,
                   status == errSecItemNotFound {
                    continue
                }
                errorCount += 1
                self.log.warning("Failed to migrate \(item.service):\(item.account): \(error)")
            }
        }
        
        if migratedCount > 0 {
            self.log.info("Migrated \(migratedCount) keychain items to trusted access")
        }
        if errorCount > 0 {
            self.log.warning("\(errorCount) items failed to migrate")
        }
    }
}

// MARK: - Log Category
extension LogCategories {
    static let keychainACL = "keychain-acl"
}
