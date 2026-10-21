import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTurnPerformanceDetailsTests {
    @Test
    func `percentiles use nearest rank and their own valid sample counts`() throws {
        let samples = try (1...20).map { value in
            try #require(CostUsageTurnPerformanceSample(
                completedAt: Date(timeIntervalSince1970: 1000),
                outputTokens: value * value,
                durationMilliseconds: value * 1000,
                firstTokenMilliseconds: value == 20 ? nil : value * 100))
        }
        let details = CostUsageTurnPerformanceDetails(samples: samples)
        #expect(details.p95DurationMilliseconds == 19000)
        #expect(details.p95FirstTokenMilliseconds == nil)
        #expect(details.outputRateLowerQuartile == 5)
        #expect(details.outputRateUpperQuartile == 15)
        #expect(CostUsageTurnPerformanceDetails(samples: Array(samples.prefix(3))).outputRateLowerQuartile == nil)
        #expect(CostUsageTurnPerformanceDetails(samples: Array(samples.prefix(19))).p95DurationMilliseconds == nil)
    }

    @Test
    func `cache ratio is input weighted and excludes unavailable counters`() throws {
        func sample(_ input: Int?, _ cached: Int?) throws -> CostUsageTurnPerformanceSample {
            try #require(CostUsageTurnPerformanceSample(
                completedAt: Date(),
                outputTokens: 10,
                durationMilliseconds: 1000,
                inputTokens: input,
                cachedInputTokens: cached))
        }
        let details = try CostUsageTurnPerformanceDetails(samples: [
            sample(100, 100), sample(900, 0), sample(100, 101), sample(nil, nil),
        ])
        #expect(details.cachedInputFraction == 0.1)
        #expect(details.cacheSampleCount == 2)
        #expect(try CostUsageTurnPerformanceDetails(samples: [sample(0, 0)]).cachedInputFraction == nil)
        #expect(try CostUsageTurnPerformanceDetails(samples: [
            sample(Int.max, 0), sample(1, 0),
        ]).cachedInputFraction == nil)
    }

    @Test
    func `model and effort groups preserve unknown attribution and use weighted speed`() throws {
        func sample(_ model: String?, _ effort: String?, _ duration: Int) throws -> CostUsageTurnPerformanceSample {
            try #require(CostUsageTurnPerformanceSample(
                completedAt: Date(),
                outputTokens: 100,
                durationMilliseconds: duration,
                firstTokenMilliseconds: duration == 1000 ? 100 : nil,
                model: model,
                reasoningEffort: effort))
        }
        let details = try CostUsageTurnPerformanceDetails(samples: [
            sample("gpt-5.4", "high", 1000), sample("gpt-5.4", "high", 9000),
            sample("gpt-5.4", "low", 1000), sample(nil, nil, 1000),
        ])
        let high = try #require(details.groups.first { $0.reasoningEffort == "high" })
        #expect(details.groups.count == 3)
        #expect(high.sampleCount == 2)
        #expect(high.outputTokensPerSecond == 20)
        #expect(high.medianDurationMilliseconds == 5000)
        #expect(high.firstTokenSampleCount == 1)
        #expect(high.medianFirstTokenMilliseconds == 100)
        #expect(details.groups.contains { $0.model == nil && $0.reasoningEffort == nil })
    }
}
