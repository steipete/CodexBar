import Foundation

enum ClaudeOAuthUsageRateLimitGate {
    private static let blockedUntilKey = "claudeOAuthUsageRateLimitBlockedUntilV1"
    private static let defaultCooldown: TimeInterval = 60 * 5

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

    static func recordRateLimit(retryAfter: Date?, now: Date = Date()) {
        let blockedUntil = if let retryAfter, retryAfter > now {
            retryAfter
        } else {
            now.addingTimeInterval(self.defaultCooldown)
        }
        UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: self.blockedUntilKey)
    }

    static func recordSuccess() {
        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
    }

    #if DEBUG
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
    }
    #endif
}
