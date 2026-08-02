import Foundation
import Testing
@testable import CodexBarCore

@Suite("Codex Models analytics parity")
struct CodexModelsAnalyticsParityTests {
    @Test
    func `per model parity canonicalizes aliases with audited cost`() throws {
        let current = DateInterval(
            start: Date(timeIntervalSince1970: 1_000_000),
            duration: 7 * 24 * 60 * 60)
        let previous = DateInterval(
            start: current.start.addingTimeInterval(-current.duration),
            duration: current.duration)
        let currentFragments = [
            self.fragment(
                day: current.start,
                model: "GPT-5.4",
                input: 6,
                session: "current",
                costNanos: 30),
            self.fragment(
                day: current.start,
                model: "openai/gpt-5.4",
                input: 4,
                session: "current",
                costNanos: 20),
        ]
        let previousFragments = [self.fragment(
            day: previous.start,
            model: "gpt-5.4",
            input: 5,
            session: "previous",
            costNanos: 10)]
        let currentKnownCost = try #require(Decimal(string: "0.00000005"))
        let previousKnownCost = try #require(Decimal(string: "0.00000001"))
        let snapshot = CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: currentFragments, previous: previousFragments),
            scopeID: nil,
            periods: CodexModelsAnalyticsPeriods(current: current, previous: previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: current.end, indexRevision: "fixture"),
            legacy: CodexModelsLegacyBaseline(
                totalTokens: 10,
                modelIDs: ["gpt-5.4"],
                knownCost: currentKnownCost,
                pricedTokens: 10,
                unpricedTokens: 0,
                activeModelCount: 1,
                topModelID: "gpt-5.4",
                sessionReferenceTotal: 1,
                previousTotalTokens: 5,
                previousKnownCost: previousKnownCost,
                previousUnpricedTokens: 0,
                previousSessionReferenceTotal: 1,
                currentModels: [CodexModelsLegacyModelBaseline(
                    modelID: "gpt-5.4",
                    totalTokens: 10,
                    knownCost: currentKnownCost,
                    pricedTokens: 10,
                    unpricedTokens: 0,
                    sessionReferences: 1)],
                previousModels: [CodexModelsLegacyModelBaseline(
                    modelID: "gpt-5.4",
                    totalTokens: 5,
                    knownCost: previousKnownCost,
                    pricedTokens: 5,
                    unpricedTokens: 0,
                    sessionReferences: 1)])))

        let row = try #require(snapshot.rows.first)
        #expect(row.id == "gpt-5.4")
        #expect(row.cost.knownAmount == currentKnownCost)
        #expect(row.cost.pricedTokens == 10)
        #expect(row.cost.unpricedTokens == 0)
        #expect(snapshot.diagnostics.isMatched)
    }

    private func fragment(
        day: Date,
        model: String,
        input: Int64,
        session: String,
        costNanos: Int64) -> CodexModelsUsageFragment
    {
        CodexModelsUsageFragment(
            workspaceID: "workspace",
            sessionID: session,
            day: day,
            rawModelID: model,
            inputTokens: input,
            cachedInputTokens: 0,
            outputTokens: 0,
            costNanos: costNanos)
    }
}
