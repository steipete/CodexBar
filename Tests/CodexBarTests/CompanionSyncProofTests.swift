import Foundation
import Testing
@testable import CodexBar

/// Proof for the macOS→iOS companion sync path. The payload that crosses iCloud KVS
/// is plain JSON, so this verifies it survives an encode (macOS writer) → decode
/// (iOS reader) round-trip intact, and that the iOS content filter keeps cards that
/// carry real content even when they have no quota metrics.
@Suite("Companion KVS sync")
struct CompanionSyncProofTests {
    private func metric(id: String = "5h", percent: Double = 42) -> CompanionCardModel.Metric {
        CompanionCardModel.Metric(
            id: id, title: "Session", percent: percent, percentLabel: "\(Int(percent))%",
            accessibilityLabel: "\(Int(percent)) percent", statusText: nil, resetText: "Resets in 3h",
            detailText: nil, detailLeftText: nil, detailRightText: nil, pacePercent: nil,
            paceOnTop: false, warningMarkerPercents: [], cardStyle: false)
    }

    private func makeCard(
        provider: String = "Codex",
        metrics: [CompanionCardModel.Metric] = [],
        providerCost: CompanionCardModel.ProviderCostSection? = nil,
        tokenUsage: CompanionCardModel.TokenUsageSection? = nil,
        creditsText: String? = nil,
        usageNotes: [String] = [],
        placeholder: String? = nil) -> CompanionCardModel
    {
        CompanionCardModel(
            providerName: provider, email: "user@example.com", subtitleText: "Pro",
            subtitleIsError: false, planText: "Pro", metrics: metrics, usageNotes: usageNotes,
            creditsText: creditsText, creditsRemaining: nil, creditsHintText: nil,
            creditsHintCopyText: nil, providerCost: providerCost, tokenUsage: tokenUsage,
            placeholder: placeholder, progressColorHex: "#007AFF",
            updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("Payload survives the JSON round-trip that crosses iCloud KVS")
    func payloadRoundTrips() throws {
        let original = [
            makeCard(provider: "Codex", metrics: [metric(id: "5h", percent: 42)]),
            makeCard(provider: "Claude", metrics: [metric(id: "7d", percent: 95)]),
        ]
        let encoded = try JSONEncoder().encode(original) // macOS writer → KVS value
        let decoded = try JSONDecoder().decode([CompanionCardModel].self, from: encoded) // iOS reader
        #expect(decoded.count == 2)
        #expect(decoded.map(\.providerName) == ["Codex", "Claude"])
        #expect(decoded[0].metrics.first?.percent == 42)
        #expect(decoded[1].metrics.first?.percentLabel == "95%")
    }

    @Test("Content filter keeps content-bearing cards that have no quota metrics")
    func keepsNonMetricCards() {
        let costOnly = makeCard(metrics: [], providerCost: .init(
            title: "Spend", percentUsed: nil, spendLine: "$12.00", percentLine: nil))
        let noteOnly = makeCard(metrics: [], usageNotes: ["Logged in"])
        let placeholderOnly = makeCard(metrics: [], placeholder: "Not logged in")
        let emptyCard = makeCard(metrics: [])

        #expect(costOnly.hasDisplayableContent)
        #expect(noteOnly.hasDisplayableContent)
        #expect(placeholderOnly.hasDisplayableContent)
        #expect(emptyCard.hasDisplayableContent == false) // truly-empty card is still dropped
    }
}
