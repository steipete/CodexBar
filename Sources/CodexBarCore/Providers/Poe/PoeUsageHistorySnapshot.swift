import Foundation

public struct PoeUsageHistorySnapshot: Codable, Equatable, Sendable {
    public struct BreakdownItem: Equatable, Sendable {
        public let name: String
        public let points: Double
        public let requests: Int
        public let costUSD: Double?
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let createdAt: Date
        public let model: String
        public let usageType: String
        public let points: Double
        public let costUSD: Double?

        public init(
            id: String,
            createdAt: Date,
            model: String,
            usageType: String,
            points: Double,
            costUSD: Double?)
        {
            self.id = id
            self.createdAt = createdAt
            self.model = model
            self.usageType = usageType
            self.points = points
            self.costUSD = costUSD
        }
    }

    public struct DailyBucket: Codable, Equatable, Sendable, Identifiable {
        public let day: String
        public let points: Double
        public let requests: Int
        public let costUSD: Double?

        public init(day: String, points: Double, requests: Int, costUSD: Double?) {
            self.day = day
            self.points = points
            self.requests = requests
            self.costUSD = costUSD
        }

        public var id: String {
            self.day
        }
    }

    public struct Summary: Equatable, Sendable {
        public let points: Double
        public let requests: Int
        public let costUSD: Double?
    }

    public let entries: [Entry]
    public let daily: [DailyBucket]
    public let updatedAt: Date

    public init(entries: [Entry], daily: [DailyBucket], updatedAt: Date) {
        self.entries = entries.sorted { $0.createdAt < $1.createdAt }
        self.daily = daily.sorted { $0.day < $1.day }
        self.updatedAt = updatedAt
    }

    public var latestDay: Summary {
        self.summary(days: 1)
    }

    public func currentDay(now: Date = Date(), calendar: Calendar = .current) -> Summary {
        let selected = self.entries.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }
        let points = selected.reduce(0) { $0 + max(0, $1.points) }
        let costValues = selected.compactMap(\.costUSD).map { max(0, $0) }
        let cost: Double? = costValues.isEmpty ? nil : costValues.reduce(0, +)
        return Summary(points: points, requests: selected.count, costUSD: cost)
    }

    public var last7Days: Summary {
        self.summary(days: 7)
    }

    public var last30Days: Summary {
        self.summary(days: 30)
    }

    public func summary(days: Int) -> Summary {
        let selected = self.daily.suffix(max(1, days))
        let points = selected.reduce(0) { $0 + $1.points }
        let requests = selected.reduce(0) { $0 + $1.requests }
        let costValues = selected.compactMap(\.costUSD)
        let cost: Double? = costValues.isEmpty ? nil : costValues.reduce(0, +)
        return Summary(points: points, requests: requests, costUSD: cost)
    }

    public var topModel: String? {
        self.topModels.first?.name
    }

    public var topModels: [BreakdownItem] {
        self.breakdown(
            groupedBy: \.model,
            fallback: "unknown")
    }

    public var topUsageTypes: [BreakdownItem] {
        self.breakdown(
            groupedBy: \.usageType,
            fallback: "unknown")
    }

    public func recentEntries(limit: Int = 3) -> [Entry] {
        let clamped = max(1, limit)
        return Array(self.entries.sorted { $0.createdAt > $1.createdAt }.prefix(clamped))
    }

    private func breakdown(
        groupedBy keyPath: KeyPath<Entry, String>,
        fallback: String) -> [BreakdownItem]
    {
        struct Acc {
            var points: Double = 0
            var requests: Int = 0
            var costUSD: Double = 0
            var hasCost = false
        }

        var grouped: [String: Acc] = [:]
        for entry in self.entries {
            let raw = entry[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            let key = raw.isEmpty ? fallback : raw
            var row = grouped[key] ?? Acc()
            row.points += max(0, entry.points)
            row.requests += 1
            if let cost = entry.costUSD {
                row.costUSD += max(0, cost)
                row.hasCost = true
            }
            grouped[key] = row
        }

        return grouped.map { key, value in
            BreakdownItem(
                name: key,
                points: value.points,
                requests: value.requests,
                costUSD: value.hasCost ? value.costUSD : nil)
        }
        .sorted {
            if $0.points == $1.points { return $0.name < $1.name }
            return $0.points > $1.points
        }
    }

    public var topUsageType: String? {
        self.topUsageTypes.first?.name
    }
}
