import Foundation

/// Explicit, durable user consent for reading Claude Code's own Keychain item (`Claude Code-credentials`).
///
/// CodexBar 0.47.0 stopped reading that foreign item entirely because Claude Code rewrites its ACL on
/// every token refresh, which makes any granted permission temporary and causes recurring macOS password
/// dialogs (#2380). That hard stop also removed every recovery path on Claude Code 2.1.x, which stores
/// credentials Keychain-only (#2634). This consent restores the pre-0.47 direct read as an informed opt-in:
/// default OFF, never enabled silently on upgrade, and revocable at any time from Claude provider settings.
///
/// The stored flag feeds `ClaudeOAuthCredentialsStore.keychainAccessAllowed` — the single choke point for
/// the direct read, the pre-emptive freshness sync, and delegated-refresh success verification — so all
/// three paths open and close together.
public enum ClaudeOAuthDirectKeychainReadConsent {
    /// Written by the app's SettingsStore; read here through the shared application defaults domain so the
    /// CLI and helper processes resolve the same consent the app persisted.
    public static let userDefaultsKey = "claudeOAuthDirectKeychainReadAllowed"

    #if DEBUG
    @TaskLocal private static var taskOverride: Bool?

    static var taskOverrideForTesting: Bool? {
        self.taskOverride
    }
    #endif

    public static func isGranted(userDefaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        if let taskOverride {
            return taskOverride
        }
        // Unit tests must not inherit the developer's persisted consent. Tests that exercise consent use a
        // task or UserDefaults override explicitly.
        if userDefaults == nil, KeychainTestSafety.shouldIsolateUserStateUnderTests() {
            return false
        }
        #endif
        let defaults = userDefaults ?? ClaudeOAuthKeychainPromptPreference.applicationUserDefaults
        return defaults.bool(forKey: self.userDefaultsKey)
    }

    #if DEBUG
    public static func withTaskOverrideForTesting<T>(
        _ granted: Bool?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverride.withValue(granted) {
            try operation()
        }
    }

    public static func withTaskOverrideForTesting<T>(
        _ granted: Bool?,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverride.withValue(granted) {
            try await operation()
        }
    }
    #endif
}
