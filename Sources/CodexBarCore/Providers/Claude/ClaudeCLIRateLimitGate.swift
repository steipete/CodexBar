import Foundation

public enum ClaudeCLIRateLimitGate {
    private struct DefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static let blockedUntilKey = "claudeCLIUsageRateLimitBlockedUntilV1"
    private static let defaultCooldown: TimeInterval = 60 * 5
    @TaskLocal private static var defaultsOverride: DefaultsBox?

    private static var defaults: UserDefaults {
        self.defaultsOverride?.defaults ?? .standard
    }

    public static func blockedUntil(
        interaction: ProviderInteraction = ProviderInteractionContext.current,
        now: Date = Date()) -> Date?
    {
        guard interaction != .userInitiated else { return nil }
        return self.currentBlockedUntil(now: now)
    }

    public static func currentBlockedUntil(now: Date = Date()) -> Date? {
        guard let raw = self.defaults.object(forKey: self.blockedUntilKey) as? Double else {
            return nil
        }

        let blockedUntil = Date(timeIntervalSince1970: raw)
        guard blockedUntil > now else {
            self.defaults.removeObject(forKey: self.blockedUntilKey)
            return nil
        }
        return blockedUntil
    }

    public static func recordRateLimit(now: Date = Date()) {
        let blockedUntil = now.addingTimeInterval(self.defaultCooldown)
        self.defaults.set(blockedUntil.timeIntervalSince1970, forKey: self.blockedUntilKey)
    }

    public static func recordSuccess() {
        self.defaults.removeObject(forKey: self.blockedUntilKey)
    }

    #if DEBUG
    public static func resetForTesting() {
        self.defaults.removeObject(forKey: self.blockedUntilKey)
    }

    public static func withUserDefaultsForTesting<T>(
        _ defaults: UserDefaults,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$defaultsOverride.withValue(DefaultsBox(defaults: defaults), operation: operation)
    }
    #endif
}
