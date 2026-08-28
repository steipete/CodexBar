import Foundation

enum ClaudeOAuthUsageRateLimitGate {
    private static let legacyBlockedUntilKey = "claudeOAuthUsageRateLimitBlockedUntilV1"
    private static let blockedUntilKeyPrefix = "claudeOAuthUsageRateLimitBlockedUntilV2."
    static let defaultCooldown: TimeInterval = 60 * 5
    private static let lock = NSLock()

    static func blockedUntil(
        accessToken: String,
        interaction: ProviderInteraction = ProviderInteractionContext.current,
        now: Date = Date()) -> Date?
    {
        guard interaction != .userInitiated else { return nil }
        return self.currentBlockedUntil(accessToken: accessToken, now: now)
    }

    static func currentBlockedUntil(accessToken: String, now: Date = Date()) -> Date? {
        self.lock.withLock {
            self.purgeLegacyAndExpiredEntries(now: now)
            let key = self.blockedUntilKey(accessToken: accessToken)
            guard let raw = UserDefaults.standard.object(forKey: key) as? Double else {
                return nil
            }
            return Date(timeIntervalSince1970: raw)
        }
    }

    static func recordRateLimit(accessToken: String, retryAfter: Date?, now: Date = Date()) {
        self.lock.withLock {
            self.purgeLegacyAndExpiredEntries(now: now)
            let key = self.blockedUntilKey(accessToken: accessToken)
            let candidate = if let retryAfter, retryAfter > now {
                retryAfter
            } else {
                now.addingTimeInterval(self.defaultCooldown)
            }
            let existing = (UserDefaults.standard.object(forKey: key) as? Double)
                .map(Date.init(timeIntervalSince1970:))
            let blockedUntil = max(existing ?? candidate, candidate)
            UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: key)
        }
    }

    static func recordSuccess(accessToken: String, now: Date = Date()) {
        self.lock.withLock {
            self.purgeLegacyAndExpiredEntries(now: now)
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey(accessToken: accessToken))
        }
    }

    private static func blockedUntilKey(accessToken: String) -> String {
        self.blockedUntilKeyPrefix + ClaudeOAuthCredentialsStore.sha256Hex(Data(accessToken.utf8))
    }

    private static func purgeLegacyAndExpiredEntries(now: Date) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: self.legacyBlockedUntilKey)
        for (key, value) in defaults.dictionaryRepresentation()
            where key.hasPrefix(self.blockedUntilKeyPrefix)
        {
            guard let timestamp = value as? Double,
                  Date(timeIntervalSince1970: timestamp) > now
            else {
                defaults.removeObject(forKey: key)
                continue
            }
        }
    }

    #if DEBUG
    static func storageKeyForTesting(accessToken: String) -> String {
        self.blockedUntilKey(accessToken: accessToken)
    }

    static func resetForTesting() {
        self.lock.withLock {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: self.legacyBlockedUntilKey)
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix(self.blockedUntilKeyPrefix)
            {
                defaults.removeObject(forKey: key)
            }
        }
    }
    #endif
}
