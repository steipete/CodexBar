import Foundation

/// Both the paginated window fetch and the one-page plugin card use this validated minute grid.
enum OpenAILiveUsageBuilder {
    static func build(
        buckets: [OpenAILiveUsageSnapshot.Minute],
        windowMinutes: Int,
        fetchedAt: Date,
        projectID: String?) throws -> OpenAILiveUsageSnapshot
    {
        guard [15, 60, 360].contains(windowMinutes), fetchedAt.timeIntervalSince1970.isFinite,
              fetchedAt.timeIntervalSince1970 >= 0, fetchedAt.timeIntervalSince1970 <= 253_402_300_799
        else { throw OpenAILiveUsageError.parseFailure }
        let current = Int(floor(fetchedAt.timeIntervalSince1970 / 60)) * 60
        let first = current - (windowMinutes - 1) * 60
        var grid: [Int: [String: OpenAILiveUsageSnapshot.ModelUsage]] = [:]
        var tokens = 0
        var requests = 0
        for bucket in buckets {
            let seconds = bucket.start.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds <= 253_402_300_799 else {
                throw OpenAILiveUsageError.parseFailure
            }
            let minute = Int(seconds) / 60 * 60
            for model in bucket.models {
                guard [
                    model.inputTokens,
                    model.cachedInputTokens,
                    model.outputTokens,
                    model.requests,
                    model.batchTokens,
                    model.batchRequests,
                ]
                    .allSatisfy({ $0 >= 0 }), model.cachedInputTokens <= model.inputTokens,
                    model.batchRequests <= model.requests
                else { throw OpenAILiveUsageError.parseFailure }
                let totalTokens = try self.add(model.inputTokens, model.outputTokens)
                guard model.batchTokens <= totalTokens else { throw OpenAILiveUsageError.parseFailure }
                guard minute >= first, minute <= current else { continue }
                tokens = try self.add(tokens, totalTokens)
                requests = try self.add(requests, model.requests)
                let prior = grid[minute]?[model.name]
                grid[
                    minute,
                    default: [:],
                ][model.name] = try .init(
                    name: model.name,
                    inputTokens: self.add(prior?.inputTokens ?? 0, model.inputTokens),
                    cachedInputTokens: self.add(prior?.cachedInputTokens ?? 0, model.cachedInputTokens),
                    outputTokens: self.add(prior?.outputTokens ?? 0, model.outputTokens),
                    requests: self.add(prior?.requests ?? 0, model.requests),
                    batchTokens: self.add(prior?.batchTokens ?? 0, model.batchTokens),
                    batchRequests: self.add(prior?.batchRequests ?? 0, model.batchRequests))
            }
        }
        return OpenAILiveUsageSnapshot(
            minutes: (0..<windowMinutes).map { index in
                let start = first + index * 60
                return .init(
                    start: Date(timeIntervalSince1970: Double(start)),
                    models: (grid[start]?.values.map(\.self) ?? []).sorted { $0.name < $1.name })
            },
            windowMinutes: windowMinutes,
            fetchedAt: fetchedAt,
            projectID: projectID)
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= 9_007_199_254_740_991 else { throw OpenAILiveUsageError.parseFailure }
        return sum
    }
}
