import Foundation

public struct ReplayTraceSegment: Sendable, Equatable {
    public let records: [AdaptiveRefreshTraceRecord]
    public let start: Date
    public let end: Date

    var replayRecords: [AdaptiveRefreshTraceRecord] {
        guard self.records.last?.timestamp != self.end else { return self.records }
        return self.records + [.refreshCompleted(timestamp: self.end)]
    }
}

public struct ReplaySegmentationReport: Sendable, Equatable {
    public let segments: [ReplayTraceSegment]
    public let excludedGapSeconds: TimeInterval
    public let breakCount: Int
    public let graceSeconds: TimeInterval

    public var includedSpanSeconds: TimeInterval {
        self.segments.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
    }
}

/// Splits legacy traces only when observation resumes well after the last timer deadline. The
/// normal scheduled wait remains inside the preceding segment; only overdue wall time is excluded.
public enum ReplayTraceSegmenter {
    public static let defaultGraceSeconds: TimeInterval = 5 * 60

    public static func automatic(
        _ records: [AdaptiveRefreshTraceRecord],
        graceSeconds: TimeInterval = Self.defaultGraceSeconds) -> ReplaySegmentationReport
    {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first else {
            return ReplaySegmentationReport(
                segments: [], excludedGapSeconds: 0, breakCount: 0, graceSeconds: graceSeconds)
        }

        var segments: [ReplayTraceSegment] = []
        var currentRecords: [AdaptiveRefreshTraceRecord] = []
        var currentStart = first.timestamp
        var expectedDeadline: Date?
        var excludedGapSeconds: TimeInterval = 0

        for record in sorted {
            if let deadline = expectedDeadline,
               record.timestamp.timeIntervalSince(deadline) > graceSeconds,
               !currentRecords.isEmpty
            {
                let end = max(currentRecords.last!.timestamp, deadline)
                segments.append(ReplayTraceSegment(records: currentRecords, start: currentStart, end: end))
                excludedGapSeconds += max(0, record.timestamp.timeIntervalSince(end))
                currentRecords = []
                currentStart = record.timestamp
                expectedDeadline = nil
            }

            currentRecords.append(record)
            if record.kind == .decision, let delay = record.delaySeconds, delay > 0 {
                expectedDeadline = record.timestamp.addingTimeInterval(delay)
            } else if record.kind == .timerAdvanced, let candidate = record.candidateScheduledAt {
                expectedDeadline = candidate
            }
        }

        if let last = currentRecords.last {
            segments.append(ReplayTraceSegment(records: currentRecords, start: currentStart, end: last.timestamp))
        }
        return ReplaySegmentationReport(
            segments: segments,
            excludedGapSeconds: excludedGapSeconds,
            breakCount: max(0, segments.count - 1),
            graceSeconds: graceSeconds)
    }
}

extension ReplayEngine {
    public static func runSegmented(
        trace: [AdaptiveRefreshTraceRecord],
        policy: some ReplayPolicy,
        graceSeconds: TimeInterval = ReplayTraceSegmenter.defaultGraceSeconds) -> ReplayMetrics
    {
        let report = ReplayTraceSegmenter.automatic(trace, graceSeconds: graceSeconds)
        let stalenessStarts = report.segments.map { segment in
            segment.records.first(where: { $0.kind == .refreshCompleted })?.timestamp
        }
        let runs = zip(report.segments, stalenessStarts).map { segment, stalenessStart in
            self.runDetailed(
                trace: segment.replayRecords,
                policy: policy,
                stalenessStartAt: stalenessStart ?? .distantFuture)
        }
        let boundaryCensoredMenuOpenCount = zip(report.segments, stalenessStarts).reduce(0) { partial, pair in
            let (segment, stalenessStart) = pair
            return partial + segment.records.count(where: { record in
                record.kind == .menuOpen && (stalenessStart.map { record.timestamp < $0 } ?? true)
            })
        }
        let span = report.includedSpanSeconds
        let refreshCount = runs.reduce(0) { $0 + $1.metrics.totalRefreshCount }
        let stalenessSamples = runs.flatMap(\.stalenessSamples)
        return ReplayMetrics(
            policyName: policy.name,
            simulatedSpanSeconds: span,
            totalRefreshCount: refreshCount,
            refreshCountPer24h: span > 0 ? Double(refreshCount) * 86400 / span : 0,
            stalenessAtMenuOpen: StalenessStats(samples: stalenessSamples),
            constrainedCompliance: ConstrainedCompliance(
                constrainedDecisionCount: runs.reduce(0) {
                    $0 + $1.metrics.constrainedCompliance.constrainedDecisionCount
                },
                violationCount: runs.reduce(0) { $0 + $1.metrics.constrainedCompliance.violationCount }),
            interactionAdvanceCount: runs.reduce(0) { $0 + $1.metrics.interactionAdvanceCount },
            codingActiveDecisionCount: runs.reduce(0) { $0 + $1.metrics.codingActiveDecisionCount },
            codingActiveDelayViolationCount: runs.reduce(0) {
                $0 + $1.metrics.codingActiveDelayViolationCount
            },
            segmentCount: report.segments.count,
            excludedGapSeconds: report.excludedGapSeconds,
            boundaryCensoredMenuOpenCount: boundaryCensoredMenuOpenCount)
    }
}
