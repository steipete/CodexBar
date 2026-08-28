import Foundation

extension UsageStore {
    nonisolated static func limitResetBoundaryAdvanced(
        previous: Date?,
        current: Date?,
        requiresPreviousBoundary: Bool = false) -> Bool
    {
        guard let previous else { return !requiresPreviousBoundary }
        guard let current else { return false }
        return !self.areEquivalentPlanUtilizationResetBoundaries(previous, current) && current > previous
    }
}
