import Foundation

/// A forecast together with the time it was observed. A forecast is not a reset event.
public struct CostUsageQuotaResetObservation: Sendable, Equatable {
    public let capturedAt: Date
    public let resetsAt: Date

    public init(capturedAt: Date, resetsAt: Date) {
        self.capturedAt = capturedAt
        self.resetsAt = resetsAt
    }
}

extension CostUsageTokenSnapshot {
    struct QuotaResetEvidence {
        let observations: [CostUsageQuotaResetObservation]
        let resetInstants: [Date]
        let duration: TimeInterval
        let now: Date
        private let cancelledForecasts: [Date]
        private let observedRollovers: [Date]

        init(
            observations: [CostUsageQuotaResetObservation],
            resetInstants: [Date],
            duration: TimeInterval,
            now: Date)
        {
            let validObservations = observations.filter {
                $0.capturedAt.timeIntervalSince1970.isFinite && $0.resetsAt.timeIntervalSince1970.isFinite
                    && $0.capturedAt <= now && $0.resetsAt > $0.capturedAt
            }.sorted { $0.capturedAt < $1.capturedAt }
            self.observations = validObservations
            var cancelled: [Date] = []
            var rollovers: [Date] = []
            let tolerance = CostUsageTokenSnapshot.quotaWeekBoundaryTolerance
            var activeForecasts = validObservations.first.map { [$0.resetsAt] } ?? []
            for (earlier, later) in zip(validObservations, validObservations.dropFirst()) {
                guard later.capturedAt > earlier.capturedAt else { continue }
                if later.capturedAt < earlier.resetsAt,
                   abs(later.resetsAt.timeIntervalSince(earlier.resetsAt)) >= tolerance
                {
                    // Small per-refresh drift may span more than the tolerance overall.
                    // Cancel every alias of this forecast, not just its last timestamp.
                    cancelled.append(contentsOf: activeForecasts)
                    activeForecasts = [later.resetsAt]
                } else if later.capturedAt >= earlier.resetsAt {
                    if abs(later.resetsAt.addingTimeInterval(-duration).timeIntervalSince(earlier.resetsAt)) <
                        tolerance
                    {
                        rollovers.append(earlier.resetsAt)
                    }
                    activeForecasts = [later.resetsAt]
                } else {
                    activeForecasts.append(later.resetsAt)
                }
            }
            self.cancelledForecasts = cancelled.sorted()
            self.observedRollovers = rollovers.sorted()
            self.resetInstants = resetInstants.filter { $0.timeIntervalSince1970.isFinite && $0 <= now }
            self.duration = duration
            self.now = now
        }

        func isCancelled(_ next: Date) -> Bool {
            let start = next.addingTimeInterval(-self.duration)
            if self.resetInstants
                .contains(where: {
                    $0 > start.addingTimeInterval(CostUsageTokenSnapshot.quotaWeekBoundaryTolerance) && $0 < next
                })
            {
                return true
            }
            return Self.containsForecast(near: next, in: self.cancelledForecasts)
        }

        func confirms(_ instant: Date) -> Bool {
            if self.resetInstants.contains(where: { $0 == instant }) {
                return true
            }
            guard instant <= self.now, !self.isCancelled(instant) else { return false }
            return Self.containsForecast(near: instant, in: self.observedRollovers)
        }

        private static func containsForecast(near instant: Date, in sorted: [Date]) -> Bool {
            let tolerance = CostUsageTokenSnapshot.quotaWeekBoundaryTolerance
            let lower = instant.addingTimeInterval(-tolerance)
            var lo = 0
            var hi = sorted.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if sorted[mid] <= lower { lo = mid + 1 } else { hi = mid }
            }
            return lo < sorted.count && abs(sorted[lo].timeIntervalSince(instant)) < tolerance
        }
    }
}
