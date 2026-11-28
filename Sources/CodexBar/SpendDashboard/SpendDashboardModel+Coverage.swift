import CodexBarCore
import Foundation

extension SpendDashboardModel {
    static func coveredIntervals(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        displayCalendar: Calendar) -> [ClosedRange<Date>]
    {
        let sourceIntervals = Self.sourceCoveredIntervals(input: input, displayCalendar: displayCalendar)
        var clipped: [ClosedRange<Date>] = []
        for interval in sourceIntervals {
            let overlapStart = max(bounds.lowerBound, interval.lowerBound)
            let overlapEnd = min(bounds.upperBound, interval.upperBound)
            if overlapStart <= overlapEnd {
                clipped.append(overlapStart...overlapEnd)
            }
        }
        return Self.normalizedIntervals(clipped)
    }

    static func sourceCoveredIntervals(
        input: ProviderInput,
        displayCalendar: Calendar) -> [ClosedRange<Date>]
    {
        if let explicit = input.snapshot.coveredDayIntervals {
            let parsed = explicit.compactMap { interval -> ClosedRange<Date>? in
                guard let start = Self.day(
                    interval.startDay,
                    provider: input.provider,
                    displayCalendar: displayCalendar),
                    let end = Self.day(
                        interval.endDay,
                        provider: input.provider,
                        displayCalendar: displayCalendar),
                    start <= end
                else { return nil }
                return start...end
            }
            return Self.normalizedIntervals(parsed)
        }
        if input.snapshot.historyCoverageIsEstablished {
            return [Self.sourceCoverageInterval(input: input, displayCalendar: displayCalendar)]
        }
        // A truncated scan proves nothing about days it never reached, so it covers only the
        // span it actually read. Every total over that span is marked as a lower bound.
        guard input.snapshot.historyScanIsPartial,
              let observed = Self.observedCoverageInterval(input: input, displayCalendar: displayCalendar)
        else { return [] }
        return [observed]
    }

    static func normalizedIntervals(_ intervals: [ClosedRange<Date>]) -> [ClosedRange<Date>] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Date>] = [sorted[0]]
        for next in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if next.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, next.upperBound)
            } else {
                merged.append(next)
            }
        }
        return merged
    }

    /// The span of days a partial scan actually produced rows for, clamped to the scan window.
    private static func observedCoverageInterval(
        input: ProviderInput,
        displayCalendar: Calendar) -> ClosedRange<Date>?
    {
        let scanned = Self.sourceCoverageInterval(input: input, displayCalendar: displayCalendar)
        let days = input.snapshot.daily
            .compactMap { Self.day($0.date, provider: input.provider, displayCalendar: displayCalendar) }
            .filter { scanned.contains($0) }
        guard let first = days.min(), let last = days.max() else { return nil }
        return first...last
    }

    static func sourceCoverageInterval(
        input: ProviderInput,
        displayCalendar: Calendar) -> ClosedRange<Date>
    {
        let bucketCalendar = Self.bucketCalendar(for: input.provider, displayCalendar: displayCalendar)
        // Legacy plugins encode their civil windowEnd at noon UTC, independently of the viewer's zone.
        let windowEnd = input.provider.firstPartyProvider == nil
            ? bucketCalendar.date(from: Self.utcCalendar.dateComponents(
                [.year, .month, .day], from: input.snapshot.updatedAt)) ?? input.snapshot.updatedAt
            : input.snapshot.updatedAt
        let bucketEnd = bucketCalendar.startOfDay(for: windowEnd)
        let scanEnd = displayCalendar.startOfDay(for: bucketEnd)
        let scanDays = max(1, input.snapshot.historyDays)
        let bucketStart = bucketCalendar.date(byAdding: .day, value: -(scanDays - 1), to: bucketEnd) ?? bucketEnd
        let scanStart = displayCalendar.startOfDay(for: bucketStart)
        return scanStart...scanEnd
    }

    static func commonCoverageInterval(summaries: [InputSummary]) -> ClosedRange<Date>? {
        guard let first = summaries.first?.coveredInterval else { return nil }
        var intersection = first
        for summary in summaries.dropFirst() {
            guard let interval = summary.coveredInterval else { return nil }
            let start = max(intersection.lowerBound, interval.lowerBound)
            let end = min(intersection.upperBound, interval.upperBound)
            guard start <= end else { return nil }
            intersection = start...end
        }
        return intersection
    }

    static func commonCoveredIntervals(summaries: [InputSummary]) -> [ClosedRange<Date>] {
        guard var intersection = summaries.first?.coveredIntervals, !intersection.isEmpty else { return [] }
        for summary in summaries.dropFirst() {
            guard !summary.coveredIntervals.isEmpty else { return [] }
            var next: [ClosedRange<Date>] = []
            for lhs in intersection {
                for rhs in summary.coveredIntervals {
                    let start = max(lhs.lowerBound, rhs.lowerBound)
                    let end = min(lhs.upperBound, rhs.upperBound)
                    if start <= end {
                        next.append(start...end)
                    }
                }
            }
            intersection = Self.normalizedIntervals(next)
            if intersection.isEmpty { return [] }
        }
        return intersection
    }

    static func dayCount(in intervals: [ClosedRange<Date>], calendar: Calendar) -> Int {
        intervals.reduce(0) { $0 + self.dayCount(in: $1, calendar: calendar) }
    }

    static func dayCount(in interval: ClosedRange<Date>?, calendar: Calendar) -> Int {
        guard let interval,
              let first = calendar.ordinality(of: .day, in: .era, for: interval.lowerBound),
              let last = calendar.ordinality(of: .day, in: .era, for: interval.upperBound)
        else { return 0 }
        return last - first + 1
    }

    static func day(
        _ rawValue: String,
        provider: ProviderInstanceID,
        displayCalendar: Calendar) -> Date?
    {
        let bytes = Array(rawValue.utf8)
        let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9]
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              digitIndices.allSatisfy({ (48...57).contains(bytes[$0]) })
        else { return nil }
        let parts = rawValue.split(separator: "-")
        let bucketCalendar = Self.bucketCalendar(for: provider, displayCalendar: displayCalendar)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = bucketCalendar.date(from: DateComponents(year: year, month: month, day: day)),
              bucketCalendar.dateComponents([.year, .month, .day], from: date) == DateComponents(
                  year: year,
                  month: month,
                  day: day)
        else { return nil }
        return displayCalendar.startOfDay(for: date)
    }

    static func bucketCalendar(for provider: ProviderInstanceID, displayCalendar: Calendar) -> Calendar {
        // Provider-specific by design: mistral openrouter xai display calendar
        guard provider == .mistral || provider == .openrouter || provider == .xai else { return displayCalendar }
        // Mistral, OpenRouter, and xAI label daily buckets and snapshot coverage by UTC day. Map each UTC boundary into
        // the containing local dashboard day instead of reinterpreting the label as a local date.
        return self.utcCalendar
    }
}
