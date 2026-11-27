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

    @Test(arguments: [AntigravityModelQuotaSource.local, .remote])
    func `versioned gemini text models without pro or flash sharing one pool collapse into gemini pool`(
        source: AntigravityModelQuotaSource) throws
    {
        let usage = try Self.usage([
            Self.quota("MODEL_PLACEHOLDER_M901", fraction: 0.88, label: "Gemini 4 Test Alpha (High)"),
            Self.quota("MODEL_PLACEHOLDER_M902", fraction: 0.88, label: "Gemini 4 Test Alpha (Low)"),
            Self.quota("MODEL_PLACEHOLDER_M903", fraction: 0.88, label: "Gemini 4 Test Beta (Medium)"),
        ], source: source)

        #expect(usage.primary?.remainingPercent.rounded() == 88)
        #expect(usage.primary?.resetsAt == Self.reset)
        #expect(usage.extraRateWindows == nil)
    }

    @Test(arguments: [AntigravityModelQuotaSource.local, .remote])
    func `separately metered versioned gemini allowance stays visible without replacing ordinary gemini`(
        source: AntigravityModelQuotaSource) throws
    {
        let separateReset = Self.reset.addingTimeInterval(3600)
        let usage = try Self.usage([
            Self.quota("gemini-3-flash", fraction: 0.88, label: "Gemini 3 Flash"),
            Self.quota("MODEL_PLACEHOLDER_M901", fraction: 0.88, label: "Gemini 4 Test Alpha (High)"),
            Self.quota(
                "MODEL_PLACEHOLDER_M909",
                fraction: 0.20,
                reset: separateReset,
                label: "Gemini 4 Argon"),
        ], source: source)

        #expect(usage.primary?.remainingPercent.rounded() == 88)
        #expect(usage.primary?.resetsAt == Self.reset)
        let separateRow = try #require(usage.extraRateWindows?.first)
        #expect(usage.extraRateWindows?.count == 1)
        #expect(separateRow.id == "MODEL_PLACEHOLDER_M909")
        #expect(separateRow.title == "Gemini 4 Argon")
        #expect(separateRow.window.remainingPercent.rounded() == 20)
        #expect(separateRow.window.resetsAt == separateReset)
    }

    @Test(arguments: [AntigravityModelQuotaSource.local, .remote])
    func `mixed versioned gemini allowances without pro or flash stay independent`(
        source: AntigravityModelQuotaSource) throws
    {
        let separateReset = Self.reset.addingTimeInterval(3600)
        let usage = try Self.usage([
            Self.quota("MODEL_PLACEHOLDER_M901", fraction: 0.88, label: "Gemini 4 Test Alpha (High)"),
            Self.quota(
                "MODEL_PLACEHOLDER_M909",
                fraction: 0.20,
                reset: separateReset,
                label: "Gemini 4 Argon"),
        ], source: source)

        #expect(usage.primary == nil)
        #expect(usage.extraRateWindows?.count == 2)
        #expect(Set(usage.extraRateWindows?.map(\.title) ?? []) == ["Gemini 4 Test Alpha (High)", "Gemini 4 Argon"])
    }

    @Test(arguments: [AntigravityModelQuotaSource.local, .remote])
    func `unclassified selectable models mirroring a represented pool are omitted`(
        source: AntigravityModelQuotaSource) throws
    {
        let usage = try Self.usage([
            Self.quota("gemini-3-flash", fraction: 0.88, label: "Gemini 3 Flash"),
            Self.quota("MODEL_PLACEHOLDER_M901", fraction: 0.88, label: "Gemini 4 Test Alpha (High)"),
            Self.quota("MODEL_PLACEHOLDER_M910", fraction: 0.88, label: "Orchestrator (Test Alpha)"),
            Self.quota("MODEL_PLACEHOLDER_M911", fraction: 0.88, label: "Orchestrator (Test Beta)"),
        ], source: source)

        #expect(usage.primary?.remainingPercent.rounded() == 88)
        #expect(usage.extraRateWindows == nil)
    }

    @Test(arguments: [AntigravityModelQuotaSource.local, .remote])
    func `unclassified selectable models with distinct fraction or reset stay visible`(
        source: AntigravityModelQuotaSource) throws
    {
        let usage = try Self.usage([
            Self.quota("gemini-3-flash", fraction: 0.88, label: "Gemini 3 Flash"),
            Self.quota("MODEL_PLACEHOLDER_M910", fraction: 0.62, label: "Orchestrator (Distinct Fraction)"),
            Self.quota(
                "MODEL_PLACEHOLDER_M911",
                fraction: 0.88,
                reset: Self.reset.addingTimeInterval(60),
                label: "Orchestrator (Distinct Reset)"),
            Self.quota("MODEL_PLACEHOLDER_M912", fraction: 0.88, reset: nil, label: "Orchestrator (No Reset)"),
        ], source: source)

        #expect(usage.primary?.remainingPercent.rounded() == 88)
        #expect(
            Set(usage.extraRateWindows?.map(\.id) ?? []) == [
                "MODEL_PLACEHOLDER_M910",
                "MODEL_PLACEHOLDER_M911",
                "MODEL_PLACEHOLDER_M912",
            ])
    }
}
