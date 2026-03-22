import Foundation
#if os(macOS)
import Security
#endif

/// Helpers for using the macOS Data Protection keychain instead of the legacy
/// login keychain.
///
/// The legacy login keychain validates "Always Allow" grants against the
/// binary's **code directory hash**. Every Sparkle update replaces the binary,
/// changing the hash and invalidating all prior grants — causing repeated
/// permission prompts.
///
/// The Data Protection keychain (`kSecUseDataProtectionKeychain`) with a
/// team-scoped `keychain-access-groups` entitlement validates access by
/// **Developer ID team** instead. Items survive binary updates as long as the
/// signing team stays the same.
public enum DataProtectionKeychain {
    /// Keychain access group matching the `keychain-access-groups` entitlement.
    /// Format: `<TeamID>.<identifier>`.
    public static let accessGroup = "Y5PE65HELJ.com.steipete.codexbar"

    #if os(macOS)
    /// Add Data Protection keychain attributes to a query dictionary.
    ///
    /// Call this on every `SecItem*` query for CodexBar-owned items so they
    /// route through the Data Protection keychain instead of the legacy login
    /// keychain. This eliminates permission prompts after Sparkle updates.
    ///
    /// For ad-hoc builds without the `keychain-access-groups` entitlement the
    /// attributes are still added; `SecItem*` calls will fall back gracefully
    /// (the entitlement is only enforced for Data Protection keychain items
    /// that specify an access group).
    public static func apply(to query: inout [String: Any]) {
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrAccessGroup as String] = accessGroup
    }
    #endif
}
