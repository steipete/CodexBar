import Foundation

/// In-memory session state for Antigravity provider.
/// Resets to defaults on app restart.
public enum AntigravitySessionState: Sendable {
    /// When `true`, the API fetch strategy takes priority over local probe.
    /// Set to `true` after user explicitly clicks "Switch Account" and logs in.
    /// Resets to `false` on app restart (in-memory only, not persisted).
    public nonisolated(unsafe) static var preferRemote: Bool = false
}
