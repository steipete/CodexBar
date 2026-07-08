import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared Live Activity contract. Referenced by the app (to start/update/end activities) and by
/// the widget extension (to render them). Guarded so the file still compiles on platforms without
/// ActivityKit (e.g. the macOS test target that runs the wire-contract check).
#if canImport(ActivityKit)
public struct UsageActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Provider raw value (e.g. "codex") this activity is tracking.
        public var providerRawValue: String
        public var providerDisplayName: String
        /// Headline "remaining %" for the tracked window (0...100).
        public var remainingPercent: Double
        /// Short label for the tracked window, e.g. "Session" or "Weekly".
        public var windowLabel: String
        /// When the tracked window resets, if known.
        public var resetsAt: Date?
        public var updatedAt: Date

        public init(
            providerRawValue: String,
            providerDisplayName: String,
            remainingPercent: Double,
            windowLabel: String,
            resetsAt: Date? = nil,
            updatedAt: Date = Date())
        {
            self.providerRawValue = providerRawValue
            self.providerDisplayName = providerDisplayName
            self.remainingPercent = remainingPercent
            self.windowLabel = windowLabel
            self.resetsAt = resetsAt
            self.updatedAt = updatedAt
        }
    }

    /// Stable identifier for the tracked provider (used to find/update the running activity).
    public var providerRawValue: String

    public init(providerRawValue: String) {
        self.providerRawValue = providerRawValue
    }
}
#endif
