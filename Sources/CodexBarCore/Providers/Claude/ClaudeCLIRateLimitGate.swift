import Foundation

enum ClaudeCLIRateLimitGate {
    private static let blockedUntilKey = "claudeCLIUsageRateLimitBlockedUntilV1"
    private static let defaultCooldown: TimeInterval = 60 * 5

    static let message = "Claude CLI usage endpoint is rate limited right now. Please try again later."

    static func blockedUntil(
        interaction: ProviderInteraction = ProviderInteractionContext.current,
        now: Date = Date()) -> Date?
    {
        guard interaction != .userInitiated else { return nil }
        return self.currentBlockedUntil(now: now)
    }

    static func currentBlockedUntil(now: Date = Date()) -> Date? {
        guard let raw = UserDefaults.standard.object(forKey: self.blockedUntilKey) as? Double else {
            return nil
        }

        let blockedUntil = Date(timeIntervalSince1970: raw)
        guard blockedUntil > now else {
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
            return nil
        }
        return blockedUntil
    }

    static func recordRateLimit(now: Date = Date()) {
        UserDefaults.standard.set(
            now.addingTimeInterval(self.defaultCooldown).timeIntervalSince1970,
            forKey: self.blockedUntilKey)
    }

    static func recordSuccess() {
        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
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
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
    }
    #endif
}
