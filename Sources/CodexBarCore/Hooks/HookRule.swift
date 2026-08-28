import Foundation

/// A user-configured hook: when `event` fires (optionally scoped to `provider`
/// and, for `quotaLow`, gated by `threshold`), run `executable` with `arguments`.
public struct HookRule: Codable, Sendable, Equatable, Identifiable {
    public static let minimumTimeoutSeconds: Double = 0.1
    public static let maximumTimeoutSeconds: Double = 300
    public static let maximumIDBytes = 128
    public static let maximumArgumentCount = 32
    public static let maximumStringBytes = 4096
    public static let maximumCommandBytes = 32 * 1024

    /// Stable identity for SwiftUI list editing; defaults to a fresh UUID string.
    public var id: String
    public var enabled: Bool
    public var event: HookEventType
    /// Provider raw value (e.g. "codex"). Nil matches any provider.
    public var provider: String?
    /// For `quotaLow`: fire only when `usagePercent >= threshold` (0...1). Ignored otherwise.
    public var threshold: Double?
    public var executable: String
    public var arguments: [String]
    public var timeoutSeconds: Double

    public static let defaultTimeoutSeconds: Double = 10

    public init(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        event: HookEventType,
        provider: String? = nil,
        threshold: Double? = nil,
        executable: String,
        arguments: [String] = [],
        timeoutSeconds: Double = HookRule.defaultTimeoutSeconds)
    {
        self.id = id
        self.enabled = enabled
        self.event = event
        self.provider = provider
        self.threshold = threshold
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.event = try container.decode(HookEventType.self, forKey: .event)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.threshold = try container.decodeIfPresent(Double.self, forKey: .threshold)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? Self.defaultTimeoutSeconds
    }

    /// True when this rule should run for the given event.
    ///
    /// Requires an absolute executable path: hook commands are never resolved via
    /// PATH or a shell, so a relative path can never match.
    public func matches(_ event: HookEvent) -> Bool {
        guard self.enabled else { return false }
        guard self.event == event.event else { return false }
        guard self.hasValidExecutablePath, self.hasValidTimeout, self.hasValidCommandShape else { return false }
        guard self.provider == nil || self.hasKnownProvider else { return false }
        guard self.hasValidThreshold else { return false }
        if let provider = self.provider, provider != event.provider {
            return false
        }
        if self.event == .quotaLow, let threshold = self.threshold {
            guard let usage = event.usagePercent, usage >= threshold else { return false }
        }
        return true
    }

    public var hasValidExecutablePath: Bool {
        !self.executable.isEmpty
            && self.executable.utf8.count <= Self.maximumStringBytes
            && (self.executable as NSString).isAbsolutePath
    }

    public var hasValidTimeout: Bool {
        self.timeoutSeconds.isFinite
            && Self.minimumTimeoutSeconds...Self.maximumTimeoutSeconds ~= self.timeoutSeconds
    }

    public var hasKnownProvider: Bool {
        guard let provider = self.provider else { return true }
        return UsageProvider(rawValue: provider) != nil
    }

    public var hasValidThreshold: Bool {
        guard let threshold = self.threshold else { return true }
        return threshold.isFinite && threshold > 0 && threshold <= 1
    }

    public var hasValidCommandShape: Bool {
        guard !self.id.isEmpty, self.id.utf8.count <= Self.maximumIDBytes else { return false }
        guard self.arguments.count <= Self.maximumArgumentCount else { return false }
        guard self.arguments.allSatisfy({ $0.utf8.count <= Self.maximumStringBytes }) else { return false }
        return self.executable.utf8.count + self.arguments.reduce(0) { $0 + $1.utf8.count }
            <= Self.maximumCommandBytes
    }
}

public enum QuotaLowHookThreshold {
    /// Returns the quota_low rules whose watched threshold was crossed upward
    /// between `previousUsage` and `currentUsage` (both 0...1 usage fractions).
    ///
    /// A rule with an explicit `threshold` watches only that value, so its own
    /// usage threshold drives emission independently of the notification
    /// thresholds. A rule without a threshold falls back to `fallbackThresholds`
    /// (the provider's notification thresholds, as usage fractions) so a plain
    /// "notify me when quota is low" hook still fires at the app's warning points.
    public static func crossedRules(
        _ rules: [HookRule],
        previousUsage: Double,
        currentUsage: Double,
        fallbackThresholds: [Double]) -> [HookRule]
    {
        rules.filter { rule in
            let watched = rule.threshold.map { [$0] } ?? fallbackThresholds
            return watched.contains { previousUsage < $0 && currentUsage >= $0 }
        }
    }
}

/// The top-level `hooks` section of the shared CodexBar config. Absent or
/// `enabled == false` means hooks never run.
public struct HooksConfig: Codable, Sendable, Equatable {
    public static let maximumRuleCount = 32

    public var enabled: Bool
    public var events: [HookRule]

    public init(enabled: Bool = false, events: [HookRule] = []) {
        self.enabled = enabled
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.events = try container.decodeIfPresent([HookRule].self, forKey: .events) ?? []
    }

    /// Enabled rules that match the event. Returns nothing when hooks are disabled.
    public func matchingRules(for event: HookEvent) -> [HookRule] {
        guard self.enabled, self.events.count <= Self.maximumRuleCount else { return [] }
        return self.events.filter { $0.matches(event) }
    }
}
