import Foundation

enum ClaudeCLIRateLimitGate {
    private static let blockedUntilKey = "claudeCLIUsageRateLimitBlockedUntilV1"
    private static let defaultCooldown: TimeInterval = 60 * 5

    static let message = "Claude CLI usage endpoint is rate limited right now. Please try again later."

    static func blockedUntil(
        environment: [String: String] = [:],
        interaction: ProviderInteraction = ProviderInteractionContext.current,
        now: Date = Date()) -> Date?
    {
        guard interaction != .userInitiated else { return nil }
        return self.currentBlockedUntil(environment: environment, now: now)
    }

    static func currentBlockedUntil(environment: [String: String] = [:], now: Date = Date()) -> Date? {
        let key = self.storageKey(environment: environment)
        guard let raw = UserDefaults.standard.object(forKey: key) as? Double else {
            return nil
        }

        let blockedUntil = Date(timeIntervalSince1970: raw)
        guard blockedUntil > now else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return blockedUntil
    }

    static func recordRateLimit(environment: [String: String] = [:], now: Date = Date()) {
        UserDefaults.standard.set(
            now.addingTimeInterval(self.defaultCooldown).timeIntervalSince1970,
            forKey: self.storageKey(environment: environment))
    }

    static func recordSuccess(environment: [String: String] = [:]) {
        UserDefaults.standard.removeObject(forKey: self.storageKey(environment: environment))
    }

    /// The default profile keeps the original key. Each explicit `CLAUDE_CONFIG_DIR` gets its own cooldown so one
    /// rate-limited profile does not pause the others.
    static func storageKey(environment: [String: String]) -> String {
        guard let configDirectory = environment[ClaudeConfigPaths.configDirectoryEnvironmentKey],
              !configDirectory.isEmpty
        else { return self.blockedUntilKey }
        return "\(self.blockedUntilKey).\(configDirectory)"
    }

    static func isRateLimitError(_ error: Error) -> Bool {
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            return self.isRateLimitMessage(message, allowRawRateLimitToken: true)
        }
        if case let ClaudeUsageError.parseFailed(message) = error {
            return self.isRateLimitMessage(message, allowRawRateLimitToken: true)
        }
        return self.isRateLimitMessage(error.localizedDescription, allowRawRateLimitToken: false)
    }

    private static func isRateLimitMessage(_ message: String, allowRawRateLimitToken: Bool) -> Bool {
        let lower = message.lowercased()
        return lower.contains(Self.message.lowercased()) ||
            (allowRawRateLimitToken && lower.contains("rate_limit_error")) ||
            (lower.contains("claude cli") &&
                lower.contains("usage") &&
                lower.contains("rate limited"))
    }

    #if DEBUG
    static func resetForTesting(environment: [String: String] = [:]) {
        UserDefaults.standard.removeObject(forKey: self.storageKey(environment: environment))
    }
    #endif
}
