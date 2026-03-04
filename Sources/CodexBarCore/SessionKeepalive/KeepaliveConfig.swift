import Foundation

/// Configuration for session keepalive behavior.
///
/// Defines how and when a provider's session should be refreshed to prevent expiration.
public struct KeepaliveConfig: Sendable, Codable, Equatable {
    // MARK: - Refresh Mode

    /// Defines when session refresh should occur.
    public enum Mode: Sendable, Codable, Equatable {
        /// Refresh at regular intervals (e.g., every 30 minutes).
        case interval(TimeInterval)

        /// Refresh daily at a specific time (24-hour format).
        case daily(hour: Int, minute: Int)

        /// Refresh before session expiry with a buffer time.
        case beforeExpiry(buffer: TimeInterval)

        // MARK: - Codable

        private enum CodingKeys: String, CodingKey {
            case type
            case interval
            case hour
            case minute
            case buffer
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            switch type {
            case "interval":
                let interval = try container.decode(TimeInterval.self, forKey: .interval)
                self = .interval(interval)
            case "daily":
                let hour = try container.decode(Int.self, forKey: .hour)
                let minute = try container.decode(Int.self, forKey: .minute)
                self = .daily(hour: hour, minute: minute)
            case "beforeExpiry":
                let buffer = try container.decode(TimeInterval.self, forKey: .buffer)
                self = .beforeExpiry(buffer: buffer)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown mode type: \(type)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .interval(let interval):
                try container.encode("interval", forKey: .type)
                try container.encode(interval, forKey: .interval)
            case .daily(let hour, let minute):
                try container.encode("daily", forKey: .type)
                try container.encode(hour, forKey: .hour)
                try container.encode(minute, forKey: .minute)
            case .beforeExpiry(let buffer):
                try container.encode("beforeExpiry", forKey: .type)
                try container.encode(buffer, forKey: .buffer)
            }
        }
    }

    // MARK: - Properties

    /// The refresh mode (interval, daily, or before expiry).
    public let mode: Mode

    /// Whether keepalive is enabled for this provider.
    public let enabled: Bool

    /// Minimum time between refresh attempts (rate limiting).
    /// Default: 120 seconds (2 minutes).
    public let minRefreshInterval: TimeInterval

    /// Maximum number of consecutive failures before auto-disabling.
    /// Default: 5 failures.
    public let maxConsecutiveFailures: Int

    // MARK: - Initialization

    public init(
        mode: Mode,
        enabled: Bool = true,
        minRefreshInterval: TimeInterval = 120,
        maxConsecutiveFailures: Int = 5)
    {
        self.mode = mode
        self.enabled = enabled
        self.minRefreshInterval = minRefreshInterval
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    // MARK: - Defaults

    /// Default configuration for Augment (refresh 5 minutes before expiry).
    public static var augmentDefault: KeepaliveConfig {
        KeepaliveConfig(mode: .beforeExpiry(buffer: 300), enabled: true)
    }

    /// Default configuration for Claude (refresh every 30 minutes).
    public static var claudeDefault: KeepaliveConfig {
        KeepaliveConfig(mode: .interval(1800), enabled: true)
    }

    /// Default configuration for Codex (refresh every 60 minutes).
    public static var codexDefault: KeepaliveConfig {
        KeepaliveConfig(mode: .interval(3600), enabled: true)
    }

    /// Disabled keepalive configuration.
    public static var disabled: KeepaliveConfig {
        KeepaliveConfig(mode: .interval(3600), enabled: false)
    }
}

// MARK: - CustomStringConvertible

extension KeepaliveConfig: CustomStringConvertible {
    public var description: String {
        let status = self.enabled ? "enabled" : "disabled"
        let modeDesc: String
        switch self.mode {
        case .interval(let seconds):
            modeDesc = "every \(Int(seconds))s"
        case .daily(let hour, let minute):
            modeDesc = "daily at \(String(format: "%02d:%02d", hour, minute))"
        case .beforeExpiry(let buffer):
            modeDesc = "\(Int(buffer))s before expiry"
        }
        return "KeepaliveConfig(\(status), \(modeDesc))"
    }
}

