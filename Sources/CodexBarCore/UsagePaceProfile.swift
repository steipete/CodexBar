import Foundation

public enum UsagePaceModel: String, Codable, Sendable {
    case linear
    case timeOfDayProfile
}

public enum UsagePaceConfidence: String, Codable, Sendable {
    case high
    case low
}

public struct UsagePaceProfile: Codable, Equatable, Sendable {
    public static let binsPerWeek = 7 * 24
    public static let minimumSampleCount = 20
    public static let minimumActiveBinCount = 8
    public static let minimumSpanHours = 48

    public let hourlyIntensity: [Double]
    public let sampleCount: Int
    public let activeBinCount: Int
    public let spanHours: Int

    public init(
        hourlyIntensity: [Double],
        sampleCount: Int,
        activeBinCount: Int,
        spanHours: Int)
    {
        let normalized = Self.normalizeBins(hourlyIntensity)
        self.hourlyIntensity = normalized
        self.sampleCount = max(0, sampleCount)
        self.activeBinCount = max(0, min(Self.binsPerWeek, activeBinCount))
        self.spanHours = max(0, spanHours)
    }

    public static var empty: UsagePaceProfile {
        UsagePaceProfile(
            hourlyIntensity: Array(repeating: 0, count: binsPerWeek),
            sampleCount: 0,
            activeBinCount: 0,
            spanHours: 0)
    }

    public var hasSufficientData: Bool {
        self.sampleCount >= Self.minimumSampleCount &&
            self.activeBinCount >= Self.minimumActiveBinCount &&
            self.spanHours >= Self.minimumSpanHours
    }

    public static func binIndex(for date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        let weekdayMondayZero = (weekday + 5) % 7
        return (weekdayMondayZero * 24) + hour
    }

    public func intensity(at date: Date, calendar: Calendar = .current) -> Double {
        let index = Self.binIndex(for: date, calendar: calendar)
        guard self.hourlyIntensity.indices.contains(index) else { return 0 }
        return max(0, self.hourlyIntensity[index])
    }

    public func integratedIntensity(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current) -> Double
    {
        guard end > start else { return 0 }

        var total = 0.0
        var cursor = start
        while cursor < end {
            let nextBoundary = self.nextHourBoundary(after: cursor, calendar: calendar)
            let segmentEnd = min(end, nextBoundary)
            let duration = segmentEnd.timeIntervalSince(cursor)
            if duration > 0 {
                total += self.intensity(at: cursor, calendar: calendar) * duration
            }
            cursor = segmentEnd
        }

        return total
    }

    private func nextHourBoundary(after date: Date, calendar: Calendar) -> Date {
        if let interval = calendar.dateInterval(of: .hour, for: date) {
            let boundary = interval.end
            if boundary > date {
                return boundary
            }
        }
        return date.addingTimeInterval(3600)
    }

    private static func normalizeBins(_ values: [Double]) -> [Double] {
        let clamped = values.map { value in
            if value.isFinite {
                return max(0, value)
            }
            return 0
        }

        if clamped.count == Self.binsPerWeek {
            return clamped
        }

        if clamped.count > Self.binsPerWeek {
            return Array(clamped.prefix(Self.binsPerWeek))
        }

        return clamped + Array(repeating: 0, count: Self.binsPerWeek - clamped.count)
    }
}
