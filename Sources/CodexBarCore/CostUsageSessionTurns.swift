import Foundation

extension CostUsageScanner {
    /// Consumes the same canonical, priced rows as the hourly report, including mirror de-duplication.
    struct SessionTurns {
        private struct Accumulator {
            var firstActivity: Date?
            var lastActivity: Date?
            var input = CostUsageDailyReport.OptionalCountAccumulator(0)
            var cached = CostUsageDailyReport.OptionalCountAccumulator(0)
            var output = CostUsageDailyReport.OptionalCountAccumulator(0)
            var reasoning = CostUsageDailyReport.OptionalCountAccumulator(0)
            var reasoningIsComplete = true
            var requests = CostUsageDailyReport.OptionalCountAccumulator(0)
            var cost: Double = 0
            var costIsComplete = true
            var calls: [CostUsageSessionRequest] = []

            mutating func add(_ row: CodexUsageRow, cost: Double?, isComplete: Bool) {
                self.calls.append(SessionTurns.request(
                    row,
                    index: self.calls.count,
                    cost: cost,
                    isComplete: isComplete))
                if let date = CostUsageScanner.date(fromUnixMs: row.timestampUnixMs) {
                    self.firstActivity = self.firstActivity.map { min($0, date) } ?? date
                    self.lastActivity = self.lastActivity.map { max($0, date) } ?? date
                }
                self.input.add(row.input)
                self.cached.add(row.cached)
                self.output.add(row.output)
                self.reasoning.add(row.reasoning)
                self.reasoningIsComplete = self.reasoningIsComplete && row.reasoning != nil
                self.requests.add(1)
                if let cost, cost.isFinite, cost >= 0, isComplete {
                    self.cost += cost
                } else {
                    self.costIsComplete = false
                }
            }

            func build(id: String) -> CostUsageSessionTurn {
                CostUsageSessionTurn(
                    turnID: id,
                    firstActivity: self.firstActivity,
                    lastActivity: self.lastActivity,
                    inputTokens: self.input.value,
                    cachedInputTokens: self.cached.value,
                    outputTokens: self.output.value,
                    reasoningTokens: self.reasoningIsComplete ? self.reasoning.value : nil,
                    totalTokens: self.input.value.flatMap { input in
                        self.output.value.flatMap { CheckedSum.integers([input, $0]) }
                    },
                    requestCount: self.requests.value,
                    costUSD: self.costIsComplete && self.cost.isFinite ? self.cost : nil,
                    requests: self.calls.sorted {
                        ($0.timestamp ?? .distantFuture) < ($1.timestamp ?? .distantFuture)
                    })
            }
        }

        private var byTurn: [String: Accumulator] = [:]
        private var unattributedRequests: [CostUsageSessionRequest] = []

        mutating func add(_ row: CodexUsageRow, cost: Double?, isComplete: Bool) {
            guard let id = row.turnID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                self.unattributedRequests.append(Self.request(
                    row, index: self.unattributedRequests.count, cost: cost, isComplete: isComplete))
                return
            }
            self.byTurn[id, default: Accumulator()].add(row, cost: cost, isComplete: isComplete)
        }

        func build(report: CostUsageDailyReport) -> [CostUsageSessionTurn] {
            guard let summary = report.summary else { return [] }
            var turns = self.byTurn.map { $0.value.build(id: $0.key) }.sorted {
                let lhs = $0.firstActivity ?? .distantFuture
                let rhs = $1.firstActivity ?? .distantFuture
                if lhs != rhs { return lhs < rhs }
                return $0.id < $1.id
            }
            let input = Self.remainder(summary.totalInputTokens, turns.map(\.inputTokens))
            let cached = Self.remainder(summary.cacheReadTokens, turns.map(\.cachedInputTokens))
            let output = Self.remainder(summary.totalOutputTokens, turns.map(\.outputTokens))
            let tokens = Self.remainder(summary.totalTokens, turns.map(\.totalTokens))
            let counts = report.data.compactMap(\.requestCount)
            let requests = Self.remainder(
                counts.isEmpty ? nil : CheckedSum.integers(counts), turns.map(\.requestCount))
            guard [input, cached, output, tokens, requests].contains(where: { ($0 ?? 0) > 0 }) else { return turns }
            let priced = turns.compactMap(\.costUSD)
            let pricedTotal = priced.reduce(0, +)
            let cost: Double? = if let total = summary.totalCostUSD, priced.count == turns.count,
                                   report.data.allSatisfy({ $0.costUSD != nil }),
                                   pricedTotal.isFinite, total - pricedTotal >= -0.0000001
            {
                max(0, total - pricedTotal)
            } else {
                nil
            }
            // Missing turn ownership is a visible remainder, never an invented user instruction.
            turns.append(CostUsageSessionTurn(
                turnID: nil,
                firstActivity: nil,
                lastActivity: nil,
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                reasoningTokens: Self.remainder(summary.reasoningTokens, turns.map(\.reasoningTokens)),
                totalTokens: tokens,
                requestCount: requests,
                costUSD: cost,
                requests: self.unattributedRequests))
            return turns
        }

        private static func request(
            _ row: CodexUsageRow, index: Int, cost: Double?, isComplete: Bool) -> CostUsageSessionRequest
        {
            CostUsageSessionRequest(
                id: "request-\(index)",
                modelName: row.model,
                timestamp: CostUsageScanner.date(fromUnixMs: row.timestampUnixMs),
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                reasoningTokens: row.reasoning,
                totalTokens: CheckedSum.integers([row.input, row.output]),
                costUSD: isComplete && cost?.isFinite == true && (cost ?? -1) >= 0 ? cost : nil)
        }

        private static func remainder(_ total: Int?, _ parts: [Int?]) -> Int? {
            guard let total, total >= 0, parts.allSatisfy({ $0 != nil }),
                  let sum = CheckedSum.integers(parts.compactMap(\ .self)), sum <= total
            else { return nil }
            return total - sum
        }
    }
}
