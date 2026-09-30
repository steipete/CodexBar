import CodexBarCore
import Foundation

struct QuotaBurndownModel: Equatable, Sendable {
    private static let resetEquivalenceTolerance: TimeInterval = 2 * 60

    struct Sample: Equatable, Sendable {
        let date: Date
        let remainingPercent: Double
    }

    let start: Date
    let reset: Date
    let samples: [Sample]
    let ideal: [Sample]

    init?(history: PlanUtilizationSeriesHistory, window: RateWindow, now: Date) {
        guard window.usedPercent.isFinite,
              !window.isSyntheticPlaceholder,
              let windowMinutes = window.windowMinutes,
              windowMinutes > 0,
              let reset = window.resetsAt,
              reset.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite
        else { return nil }

        let duration = Double(windowMinutes) * 60
        guard duration.isFinite, duration > 0 else { return nil }

        let start = reset.addingTimeInterval(-duration)
        guard start.timeIntervalSinceReferenceDate.isFinite,
              start <= now,
              now < reset
        else { return nil }

        let historicalSamples = history.entries.compactMap { entry -> (Date, Double)? in
            guard entry.capturedAt >= start,
                  entry.capturedAt <= now,
                  entry.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.usedPercent.isFinite,
                  entry.resetsAt.map({
                      abs($0.timeIntervalSince(reset)) <= Self.resetEquivalenceTolerance
                  }) ?? true
            else { return nil }
            return (entry.capturedAt, entry.usedPercent)
        }

        var currentSegment: [(Date, Double)] = []
        for sample in historicalSamples + [(now, window.usedPercent)] {
            if let last = currentSegment.last {
                if sample.0 == last.0 {
                    currentSegment[currentSegment.count - 1] = sample
                    continue
                }
                if sample.1 < last.1 {
                    currentSegment.removeAll(keepingCapacity: true)
                }
            }
            currentSegment.append(sample)
        }

        self.start = start
        self.reset = reset
        self.samples = currentSegment.map { date, usedPercent in
            Sample(
                date: date,
                remainingPercent: (100 - usedPercent).clamped(to: 0...100))
        }
        self.ideal = [
            Sample(date: start, remainingPercent: 100),
            Sample(date: reset, remainingPercent: 0),
        ]
    }
}
