import Foundation

/// Keeps known subtotals, missing evidence, and invalid arithmetic independent for each metric.
struct CostUsageTemporalTotals {
    private var tokens = 0
    private var sawTokens = false
    private var tokensAreValid = true
    private var completeTokens = true
    private var cost = 0.0
    private var sawCost = false
    private var costIsValid = true
    private var completeCost = true

    var knownTokenSubtotal: Int? {
        self.tokensAreValid ? self.tokens : nil
    }

    var knownCostSubtotal: Double? {
        self.costIsValid ? self.cost : nil
    }

    var totalTokens: Int? {
        self.sawTokens && self.tokensAreValid ? self.tokens : nil
    }

    var costUSD: Double? {
        self.sawCost && self.costIsValid ? self.cost : nil
    }

    var tokensAreComplete: Bool {
        self.completeTokens && self.totalTokens != nil
    }

    var costIsComplete: Bool {
        self.completeCost && self.costUSD != nil
    }

    mutating func addTokens(_ value: Int?, isComplete: Bool = true) {
        self.completeTokens = self.completeTokens && isComplete && value != nil
        guard let value else { return }
        guard value >= 0 else {
            self.tokensAreValid = false
            return
        }
        let (sum, overflow) = self.tokens.addingReportingOverflow(value)
        self.tokensAreValid = self.tokensAreValid && !overflow
        if !overflow {
            self.tokens = sum
            self.sawTokens = true
        }
    }

    mutating func addCost(_ value: Double?, isComplete: Bool = true) {
        self.completeCost = self.completeCost && isComplete && value != nil
        guard let value else { return }
        guard value.isFinite, value >= 0 else {
            self.costIsValid = false
            return
        }
        let sum = self.cost + value
        self.costIsValid = self.costIsValid && sum.isFinite
        if sum.isFinite {
            self.cost = sum
            self.sawCost = true
        }
    }

    mutating func add(
        totalTokens: Int?,
        costUSD: Double?,
        tokensAreComplete: Bool = true,
        costIsComplete: Bool = true)
    {
        self.addTokens(totalTokens, isComplete: tokensAreComplete)
        self.addCost(costUSD, isComplete: costIsComplete)
    }

    func hourlyEntry(hour: Date) -> CostUsageHourlyEntry {
        CostUsageHourlyEntry(
            hour: hour,
            totalTokens: self.totalTokens,
            costUSD: self.costUSD,
            tokensAreComplete: self.tokensAreComplete,
            costIsComplete: self.costIsComplete)
    }

    func timedEntry(timestamp: Date) -> CostUsageTimedEntry {
        CostUsageTimedEntry(
            timestamp: timestamp,
            totalTokens: self.totalTokens,
            costUSD: self.costUSD,
            tokensAreComplete: self.tokensAreComplete,
            costIsComplete: self.costIsComplete)
    }
}
