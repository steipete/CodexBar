import Foundation

/// Shared accounting for both Mistral usage sources (legacy billing endpoint and tRPC usage procedures):
/// checked token sums, daily buckets, and per-model breakdowns.
enum MistralUsageAggregator {
    enum Lane: Equatable, Sendable {
        case input
        case cached
        case output
        case other

        init(billingGroup: String) {
            switch billingGroup {
            case "input": self = .input
            case "cached": self = .cached
            case "output": self = .output
            default: self = .other
            }
        }
    }

    enum TokenScope: Equatable, Sendable {
        /// Units are not tokens (pages, seconds, characters, calls).
        case none
        /// Tokens count in daily buckets and monthly totals.
        case all
        /// Legacy `libraries_api.tokens` policy: daily lanes only, never the monthly totals.
        case dailyOnly
    }

    struct Entry: Sendable {
        /// Day bucket key; nil keeps the entry in the monthly totals only (legacy entries without a timestamp).
        let day: String?
        /// Display name shown in breakdowns.
        let modelName: String
        /// Identity used to count distinct models.
        let modelKey: String
        let lane: Lane
        let units: Int
        let cost: Double
        let tokenScope: TokenScope
    }

    struct Period: Sendable {
        let costBasis: MistralUsageSnapshot.CostBasis
        let currency: String
        let currencySymbol: String
        let startDate: Date?
        let endDate: Date?
        let updatedAt: Date
    }

    static func snapshot(entries: [Entry], period: Period) throws -> MistralUsageSnapshot {
        var totalCost: Double = 0
        var totalTokens = TokenCounts()
        var modelKeys: Set<String> = []
        var daily: [String: DailyAccumulator] = [:]
        for entry in entries {
            Self.accumulateFiniteCost(entry.cost, into: &totalCost)
            if entry.tokenScope != .none {
                modelKeys.insert(entry.modelKey)
            }
            if entry.tokenScope == .all {
                try totalTokens.add(entry.units, lane: entry.lane)
            }
            guard let day = entry.day else { continue }
            var accumulator = daily[day] ?? DailyAccumulator(day: day)
            try accumulator.add(
                modelName: entry.modelName,
                lane: entry.lane,
                units: entry.units,
                cost: entry.cost,
                countsTokens: entry.tokenScope != .none)
            daily[day] = accumulator
        }
        _ = try totalTokens.total()
        return try MistralUsageSnapshot(
            totalCost: totalCost,
            costBasis: period.costBasis,
            currency: period.currency,
            currencySymbol: period.currencySymbol,
            totalInputTokens: totalTokens.input,
            totalOutputTokens: totalTokens.output,
            totalCachedTokens: totalTokens.cached,
            modelCount: modelKeys.count,
            daily: daily.values.map { try $0.makeBucket() },
            startDate: period.startDate,
            endDate: period.endDate,
            updatedAt: period.updatedAt)
    }

    static func accumulateFiniteCost(_ cost: Double, into total: inout Double) {
        guard cost.isFinite else { return }
        let updatedTotal = total + cost
        guard updatedTotal.isFinite else { return }
        total = updatedTotal
    }

    static func dayKey(from timestamp: String?) -> String? {
        guard let trimmed = timestamp?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count >= 10 {
            return String(trimmed.prefix(10))
        }
        return nil
    }
}

private struct TokenCounts {
    var input = 0
    var cached = 0
    var output = 0

    mutating func add(_ units: Int, lane: MistralUsageAggregator.Lane) throws {
        let path: WritableKeyPath<Self, Int>
        switch lane {
        case .input: path = \.input
        case .cached: path = \.cached
        case .output: path = \.output
        case .other: return
        }
        let addition = self[keyPath: path].addingReportingOverflow(units)
        guard !addition.overflow else { throw MistralUsageError.parseFailed("Token count exceeds supported range") }
        self[keyPath: path] = addition.partialValue
    }

    func total() throws -> Int {
        guard let total = MistralTokenMath.total(input: self.input, cached: self.cached, output: self.output) else {
            throw MistralUsageError.parseFailed("Token count exceeds supported range")
        }
        return total
    }
}

private struct DailyAccumulator {
    let day: String
    var cost: Double = 0
    var tokens = TokenCounts()
    var models: [String: ModelAccumulator] = [:]

    mutating func add(
        modelName: String,
        lane: MistralUsageAggregator.Lane,
        units: Int,
        cost: Double,
        countsTokens: Bool) throws
    {
        MistralUsageAggregator.accumulateFiniteCost(cost, into: &self.cost)
        var model = self.models[modelName] ?? ModelAccumulator(name: modelName)
        MistralUsageAggregator.accumulateFiniteCost(cost, into: &model.cost)
        if countsTokens {
            try self.tokens.add(units, lane: lane)
            try model.tokens.add(units, lane: lane)
        }
        self.models[modelName] = model
    }

    func makeBucket() throws -> MistralDailyUsageBucket {
        _ = try self.tokens.total()
        let models = try self.models.values.map { model in
            try (breakdown: model.makeBreakdown(), total: model.tokens.total())
        }.sorted {
            if $0.total == $1.total { return $0.breakdown.name < $1.breakdown.name }
            return $0.total > $1.total
        }
        return MistralDailyUsageBucket(
            day: self.day,
            cost: self.cost,
            inputTokens: self.tokens.input,
            cachedTokens: self.tokens.cached,
            outputTokens: self.tokens.output,
            models: models.map(\.breakdown))
    }
}

private struct ModelAccumulator {
    let name: String
    var cost: Double = 0
    var tokens = TokenCounts()

    func makeBreakdown() -> MistralDailyUsageBucket.ModelBreakdown {
        MistralDailyUsageBucket.ModelBreakdown(
            name: self.name,
            cost: self.cost,
            inputTokens: self.tokens.input,
            cachedTokens: self.tokens.cached,
            outputTokens: self.tokens.output)
    }
}
