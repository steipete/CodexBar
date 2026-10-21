import CoreFoundation
import Foundation

extension CostUsageScanner {
    struct CodexTurnPerformanceState: Codable, Equatable {
        var reportedOutputTokens: Int?
        var hasRejectedUsage: Bool?
        var completion: CodexTurnPerformanceCompletion?
        var reasoningEffort: String?
        var hasConflictingEffort: Bool?

        mutating func observeReasoningEffort(_ raw: String?) {
            let effort = CostUsageScanner.codexModelEvidence(raw)
            if let previous = self.reasoningEffort, previous != effort {
                self.hasConflictingEffort = true
            }
            self.reasoningEffort = effort
        }
    }

    struct CodexInvalidRequestUsage: Codable, Equatable {
        let threadID: String
        let sessionID: String?
        let turnID: String?
        var timestamp: String?
        var responseID: String?

        /// Export diagnostics are transient; preserve the original deferred-buffer schema.
        enum CodingKeys: String, CodingKey { case threadID, sessionID, turnID }
    }

    struct CodexTurnPerformanceCompletion: Codable, Equatable {
        let turnID: String
        let timestamp: String
        let completedAtUnixMs: Int64?
        let durationMilliseconds: Int?
        let firstTokenMilliseconds: Int?
        let startedAtUnixMs: Int64?
    }

    /// Decode terminal events even when timing is invalid, so a later failed event invalidates a sample.
    static func codexTurnCompletion(
        payload: [String: Any],
        timestamp: String) -> CodexTurnPerformanceCompletion?
    {
        guard let turnID = payload["turn_id"] as? String, !turnID.isEmpty else { return nil }
        let succeeded = payload["error"] == nil || payload["error"] is NSNull
        let duration = Self.codexPerformanceInteger(payload["duration_ms"])
        let startedSeconds = Self.codexPerformanceInteger(payload["started_at"])
        let started = startedSeconds.flatMap { seconds -> Int64? in
            let result = Int64(seconds).multipliedReportingOverflow(by: 1000)
            return result.overflow ? nil : result.partialValue
        }
        let validStart = payload["started_at"] == nil || payload["started_at"] is NSNull || started != nil
        return CodexTurnPerformanceCompletion(
            turnID: turnID,
            timestamp: timestamp,
            completedAtUnixMs: Self.dateFromTimestamp(timestamp).map {
                Int64(($0.timeIntervalSince1970 * 1000).rounded())
            },
            durationMilliseconds: succeeded && validStart && (duration ?? 0) > 0 ? duration : nil,
            firstTokenMilliseconds: Self.codexPerformanceInteger(payload["time_to_first_token_ms"]),
            startedAtUnixMs: started)
    }

    private static func codexPerformanceInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return nil }
        return number.intValue
    }

    static func codexTurnPerformanceSamples(
        usage: CostUsageFileUsage,
        range: CostUsageDayRange) -> [CostUsageTurnPerformanceSample]
    {
        guard let states = usage.codexRequestLedgerState?.turnPerformance, !states.isEmpty else { return [] }
        struct Output {
            var tokens = 0
            var input = 0
            var cached = 0
            var validCache = true
            var models: Set<String> = []
            var firstTimestamp: Int64 = .max
            var lastTimestamp: Int64 = .min
            var valid = true
        }
        var outputs: [String: Output] = [:]
        for row in usage.codexRows ?? [] {
            guard row.responseID != nil, let turnID = row.turnID, states[turnID] != nil else { continue }
            var output = outputs[turnID] ?? Output()
            let sum = output.tokens.addingReportingOverflow(row.output)
            output.tokens = sum.partialValue
            let inputSum = output.input.addingReportingOverflow(row.input)
            let cacheSum = output.cached.addingReportingOverflow(row.cached)
            output.input = inputSum.partialValue
            output.cached = cacheSum.partialValue
            output.validCache = output.validCache && !inputSum.overflow && !cacheSum.overflow
                && row.input >= 0 && row.cached >= 0 && row.cached <= row.input
            output.models.insert(row.rawModel ?? row.model)
            output.valid = output.valid && !sum.overflow && row.output >= 0
                && row.timestampUnixMs != nil
            if let timestamp = row.timestampUnixMs {
                output.firstTimestamp = min(output.firstTimestamp, timestamp)
                output.lastTimestamp = max(output.lastTimestamp, timestamp)
            }
            outputs[turnID] = output
        }
        return states.keys.sorted().compactMap { turnID in
            guard let state = states[turnID], state.hasRejectedUsage != true, let completion = state.completion,
                  let duration = completion.durationMilliseconds,
                  let output = outputs[turnID], output.valid, output.tokens == state.reportedOutputTokens,
                  let completedMs = completion.completedAtUnixMs
            else { return nil }
            let completedAt = Date(timeIntervalSince1970: Double(completedMs) / 1000)
            guard output.lastTimestamp <= completedMs,
                  completion.startedAtUnixMs.map({ output.firstTimestamp >= $0 }) ?? true
            else { return nil }
            let day = CostUsageDayRange.dayKey(
                from: completedAt,
                calendar: range.calendar)
            guard CostUsageDayRange.isInRange(
                dayKey: day,
                since: range.sinceKey,
                until: range.untilKey)
            else { return nil }
            return CostUsageTurnPerformanceSample(
                completedAt: completedAt,
                outputTokens: output.tokens,
                durationMilliseconds: duration,
                firstTokenMilliseconds: completion.firstTokenMilliseconds,
                model: output.models.count == 1 && output.models.first != CostUsagePricing.codexUnattributedModel
                    ? output.models.first : nil,
                reasoningEffort: state.hasConflictingEffort == true ? nil : state.reasoningEffort,
                inputTokens: output.validCache ? output.input : nil,
                cachedInputTokens: output.validCache ? output.cached : nil)
        }
    }
}
