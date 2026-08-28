import Foundation

/// Informational summary of optional coding-activity observations in a trace's `decision` events.
/// It reports how many decisions carried activity data and how many sampled decisions were below
/// `activeThresholdSeconds` for either CLI.
public struct ActivityCoverageStats: Sendable, Equatable {
    public let decisionCount: Int
    public let sampledCount: Int
    public let activeCount: Int

    public init(decisionCount: Int, sampledCount: Int, activeCount: Int) {
        self.decisionCount = decisionCount
        self.sampledCount = sampledCount
        self.activeCount = activeCount
    }

    /// Fraction of `decision` events that carried at least one non-nil activity field.
    public var sampledFraction: Double {
        self.decisionCount == 0 ? 0 : Double(self.sampledCount) / Double(self.decisionCount)
    }

    /// Fraction of the *sampled* decisions (not all decisions) that looked like active coding.
    public var activeFraction: Double {
        self.sampledCount == 0 ? 0 : Double(self.activeCount) / Double(self.sampledCount)
    }

    /// - Parameter activeThresholdSeconds: below this many seconds since the newest transcript
    ///   write, a CLI counts as "active coding at decision time". Defaults to 5 minutes.
    public static func compute(
        from records: [AdaptiveRefreshTraceRecord],
        activeThresholdSeconds: TimeInterval = 300) -> Self
    {
        var sampledCount = 0
        var activeCount = 0
        var decisionCount = 0
        for record in records where record.kind == .decision {
            decisionCount += 1
            let codexSeconds = record.codexActivitySeconds
            let claudeSeconds = record.claudeActivitySeconds
            guard codexSeconds != nil || claudeSeconds != nil else { continue }
            sampledCount += 1
            let isActive = (codexSeconds ?? .infinity) < activeThresholdSeconds
                || (claudeSeconds ?? .infinity) < activeThresholdSeconds
            if isActive {
                activeCount += 1
            }
        }
        return Self(decisionCount: decisionCount, sampledCount: sampledCount, activeCount: activeCount)
    }
}
