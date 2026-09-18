import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityPoolDeduplicationTests {
    private static let reset = Date(timeIntervalSince1970: 1_800_000_000)

    private static func quota(
        _ id: String,
        fraction: Double? = 0.7,
        reset: Date? = Self.reset,
        label: String? = nil) -> AntigravityModelQuota
    {
        AntigravityModelQuota(
            label: label ?? id,
            modelId: id,
            remainingFraction: fraction,
            resetTime: reset,
            resetDescription: "Resets later")
    }

    private static func usage(
        _ models: [AntigravityModelQuota],
        source: AntigravityModelQuotaSource = .remote) throws -> UsageSnapshot
    {
        try AntigravityStatusSnapshot(
            modelQuotas: models,
            accountEmail: nil,
            accountPlan: nil,
            source: source).toUsageSnapshot()
    }

    @Test(arguments: [AntigravityModelQuotaSource.remote, .local])
    func `only remote pool mirrors are suppressed`(source: AntigravityModelQuotaSource) throws {
        let variants = ["gemini-test-flash-lite", "gemini-test-pro-image", "tab_test_autocomplete"]
        let usage = try Self.usage(
            [Self.quota("gemini-test-flash")] + variants.map { Self.quota($0) }, source: source)
        #expect(usage.primary?.usedPercent == 30)
        #expect(Set(usage.extraRateWindows?.map(\.id) ?? []) == (source == .remote ? [] : Set(variants)))
    }

    @Test(arguments: [0.2, 0.70005, 0.8])
    func `independently consumed variants remain distinct`(fraction: Double) throws {
        let usage = try Self.usage([
            Self.quota("gemini-test-flash"),
            Self.quota("gemini-test-flash-lite", fraction: fraction),
        ])
        let row = try #require(usage.extraRateWindows?.first)
        #expect(row.id == "gemini-test-flash-lite")
        #expect(row.window.usedPercent == 100 - fraction * 100)
    }

    @Test(arguments: [0, 1, 2, 3])
    func `different or unobserved resets preserve variants`(combination: Int) throws {
        let poolReset = combination == 1 || combination == 3 ? nil : Self.reset
        let variantReset = combination == 2 || combination == 3 ? nil : Self.reset.addingTimeInterval(60)
        let usage = try Self.usage([
            Self.quota("gemini-test-flash", reset: poolReset),
            Self.quota("gemini-test-flash-lite", reset: variantReset),
        ])
        #expect(usage.extraRateWindows?.map(\.id) == ["gemini-test-flash-lite"])
    }

    @Test
    func `reset only variants retain unavailable usage`() throws {
        let usage = try Self.usage([
            Self.quota("gemini-test-flash"),
            Self.quota("gemini-test-flash-lite", fraction: nil),
        ])
        #expect(usage.extraRateWindows?.first?.usageKnown == false)
    }

    @Test(arguments: [false, true], [0.0, 0.4, 1.0])
    func `known quota wins over reset only duplicate canonical model`(reverse: Bool, fraction: Double) throws {
        let rows = [
            Self.quota("gemini-test-flash-lite", fraction: nil),
            Self.quota("gemini-test-flash-lite", fraction: fraction),
        ]
        let usage = try Self.usage(reverse ? Array(rows.reversed()) : rows)
        if fraction == 1 {
            #expect(usage.extraRateWindows == nil)
        } else {
            let row = try #require(usage.extraRateWindows?.first)
            #expect(usage.extraRateWindows?.count == 1)
            #expect(row.usageKnown)
            #expect(row.window.usedPercent == 100 - fraction * 100)
        }
    }

    @Test(arguments: [false, true])
    func `equal titles retain canonical identity as usage changes`(reverse: Bool) throws {
        let firstID = "gemini-test-flash-lite-one"
        let secondID = "gemini-test-flash-lite-two"
        for fraction in [0.3, 0.5] {
            let rows = [
                Self.quota(firstID, fraction: fraction, label: "Test Flash Lite"),
                Self.quota(secondID, fraction: 0.4, label: "Test Flash Lite"),
            ]
            let usage = try Self.usage(reverse ? Array(rows.reversed()) : rows)
            #expect(Set(usage.extraRateWindows?.map(\.id) ?? []) == [firstID, secondID])
        }
    }

    @Test
    func `autocomplete keeps its known family and unknown models stay independent`() throws {
        let usage = try Self.usage([
            Self.quota("gemini-test-flash"),
            Self.quota("claude-test-model", fraction: 0.5),
            Self.quota("claude-test-autocomplete"),
            Self.quota("orbit-test-image"),
        ])
        #expect(Set(usage.extraRateWindows?.map(\.id) ?? []) == ["claude-test-autocomplete", "orbit-test-image"])
    }

    @Test
    func `reset only pools keep Gemini then Claude order`() throws {
        let usage = try Self.usage([
            Self.quota("claude-test-model", fraction: nil),
            Self.quota("gemini-test-flash", fraction: nil),
        ])
        #expect(usage.extraRateWindows?.map(\.id) == ["antigravity-gemini", "antigravity-claude-gpt"])
    }
}
