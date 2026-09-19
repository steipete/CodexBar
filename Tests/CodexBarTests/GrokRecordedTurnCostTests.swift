import Foundation
import Testing
@testable import CodexBarCore

extension GrokCostUsagePricingTests {
    @Test(arguments: [false, true])
    func `outer recorded spend is counted once with populated model usage`(hasNestedCosts: Bool) throws {
        let summary = try self.recordedModelsSummary(
            outerTicks: 10_000_000_000,
            firstModelTicks: hasNestedCosts ? 4_000_000_000 : nil,
            secondModelTicks: hasNestedCosts ? 6_000_000_000 : nil)
        let day = try #require(summary.daily.first)
        #expect(day.costUSD == 1)
        #expect(day.totalTokens == 2000)
        #expect(day.requestCount == 2)
        #expect(day.estimatedRequestCount == 0)
        #expect(day.unpricedRequestCount == 0)
        #expect(summary.costProvenance == .vendorMetered)
        if hasNestedCosts {
            #expect(day.modelBreakdowns.compactMap(\.costUSD).reduce(0, +) == 1)
        } else {
            #expect(day.modelBreakdowns.allSatisfy { $0.costUSD == nil })
        }
    }

    @Test(arguments: [false, true])
    func `outer recorded spend wins over inconsistent or partial nested costs`(partial: Bool) throws {
        let summary = try self.recordedModelsSummary(
            outerTicks: 10_000_000_000,
            firstModelTicks: 4_000_000_000,
            secondModelTicks: partial ? nil : 80_000_000_000)
        let day = try #require(summary.daily.first)
        #expect(day.costUSD == 1)
        #expect(day.estimatedRequestCount == 0)
        #expect(day.unpricedRequestCount == 0)
        #expect(summary.costProvenance == .vendorMetered)
        #expect(day.modelBreakdowns.allSatisfy { $0.costUSD == nil })
        #expect(day.modelBreakdowns.compactMap(\.totalTokens).reduce(0, +) == 2000)
    }

    @Test(arguments: [false, true])
    func `missing or zero outer spend retains nested recorded costs`(zeroOuter: Bool) throws {
        let summary = try self.recordedModelsSummary(
            outerTicks: zeroOuter ? 0 : nil,
            firstModelTicks: 4_000_000_000,
            secondModelTicks: 6_000_000_000)
        let day = try #require(summary.daily.first)
        #expect(day.costUSD == 1)
        #expect(day.modelBreakdowns.compactMap(\.costUSD).reduce(0, +) == 1)
        #expect(day.estimatedRequestCount == 0)
        #expect(summary.costProvenance == .vendorMetered)
    }

    @Test
    func `unattributed outer spend keeps the combined model cost unknown`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = try self.localDate(day: 20, hour: 12)
        let outerOnly = self.usage(
            input: 1000,
            output: 0,
            modelCalls: 1,
            costUsdTicks: 10_000_000_000,
            modelUsage: ["grok-4.6-build": self.modelUsage(input: 1000, output: 0, modelCalls: 1)])
        try self.writeUpdates(
            [
                self.turn(timestamp: now, usage: outerOnly),
                self.turn(timestamp: now.addingTimeInterval(1), usage: self.singleModelUsage(
                    input: 1000, output: 0, costUsdTicks: 4_000_000_000)),
            ],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: now.addingTimeInterval(60))
        let summary = try self.summarize(fixture: fixture, now: now.addingTimeInterval(120))
        let day = try #require(summary.daily.first)
        #expect(abs((day.costUSD ?? 0) - 1.4) < 1e-12)
        #expect(day.modelBreakdowns.first?.costUSD == nil)
        #expect(day.totalTokens == 2000)
        #expect(summary.costProvenance == .vendorMetered)
    }

    private func recordedModelsSummary(
        outerTicks: Int?,
        firstModelTicks: Int?,
        secondModelTicks: Int?) throws -> GrokLocalSessionSummary
    {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = try self.localDate(day: 20, hour: 12)
        let usage = self.usage(
            input: 2000,
            output: 0,
            modelCalls: 2,
            costUsdTicks: outerTicks,
            modelUsage: [
                "grok-4.6-build": self.modelUsage(
                    input: 1000, output: 0, modelCalls: 1, costUsdTicks: firstModelTicks),
                "grok-test-model": self.modelUsage(
                    input: 1000, output: 0, modelCalls: 1, costUsdTicks: secondModelTicks),
            ])
        try self.writeUpdates(
            [self.turn(timestamp: now, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: now.addingTimeInterval(60))
        return try self.summarize(fixture: fixture, now: now.addingTimeInterval(120))
    }
}
