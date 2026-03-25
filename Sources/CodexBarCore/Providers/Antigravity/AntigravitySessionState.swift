import Foundation

/// In-memory session state for Antigravity provider.
/// Resets to defaults on app restart.
public enum AntigravitySessionState: Sendable {
    actor Storage {
        private var preferRemoteValue = false

        func preferRemote() -> Bool {
            self.preferRemoteValue
        }

        func setPreferRemote(_ newValue: Bool) {
            self.preferRemoteValue = newValue
        }
    }

    private static let storage = Storage()

    /// When `true`, the API fetch strategy takes priority over local probe.
    /// Set to `true` after user explicitly clicks "Switch Account" and logs in.
    /// Resets to `false` on app restart (in-memory only, not persisted).
    public static func preferRemote() async -> Bool {
        await self.storage.preferRemote()
    }

    public static func setPreferRemote(_ newValue: Bool) async {
        await self.storage.setPreferRemote(newValue)
    }
}
