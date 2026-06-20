import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct EnvironmentalImpactTests {
    @Test
    func environmentalImpactCalculations() throws {
        // Test Mistral Large 2
        // Joules = 10_000 * 26.6 = 266,000 J
        // kWh = 266,000 / 3,600,000 = 0.073888... kWh
        // CO2 kg = 0.073888... * 0.385 = 0.028447... kg
        let mistralBreakdowns = [CostUsageDailyReport.ModelBreakdown(
            modelName: "mistral-large-latest",
            costUSD: nil,
            totalTokens: 10000)]
        let mistralImpact = try #require(EnvironmentalImpact(provider: .mistral, breakdowns: mistralBreakdowns))

        #expect(abs(mistralImpact.energyKWh - 0.073888) < 0.0001)
        #expect(abs(mistralImpact.co2Kg - 0.028447) < 0.0001)

        // Test Claude Haiku
        // Joules = 100_000 * 5.0 = 500,000 J
        // kWh = 500,000 / 3,600,000 = 0.138888... kWh
        let claudeBreakdowns = [CostUsageDailyReport.ModelBreakdown(
            modelName: "claude-3-haiku-20240307",
            costUSD: nil,
            totalTokens: 100_000)]
        let claudeImpact = try #require(EnvironmentalImpact(provider: .claude, breakdowns: claudeBreakdowns))

        #expect(abs(claudeImpact.energyKWh - 0.138888) < 0.0001)

        // Test fallback (unknown model should return nil)
        let fallbackBreakdowns = [CostUsageDailyReport.ModelBreakdown(
            modelName: "unknown-model",
            costUSD: nil,
            totalTokens: 10000)]
        #expect(EnvironmentalImpact(provider: .synthetic, breakdowns: fallbackBreakdowns) == nil)

        // Test Vertex AI Claude model
        // Joules = 100_000 * 15.0 (Sonnet) = 1,500,000 J
        // kWh = 1,500,000 / 3,600,000 = 0.41666... kWh
        let vertexClaudeBreakdowns = [CostUsageDailyReport.ModelBreakdown(
            modelName: "claude-3-5-sonnet-v2@20241022",
            costUSD: nil,
            totalTokens: 100_000)]
        let vertexClaudeImpact = try #require(
            EnvironmentalImpact(provider: .vertexai, breakdowns: vertexClaudeBreakdowns))
        #expect(abs(vertexClaudeImpact.energyKWh - 0.41666) < 0.0001)

        // Return nil when no tokens
        let emptyBreakdowns: [CostUsageDailyReport.ModelBreakdown] = []
        #expect(EnvironmentalImpact(provider: .openai, breakdowns: emptyBreakdowns) == nil)
    }

    @Test
    func energyFormatting() {
        // Less than 1 kWh (formatted as Wh)
        #expect(UsageFormatter.formatEnergy(0.0015) == "1.5 Wh")
        #expect(UsageFormatter.formatEnergy(0.0125) == "13 Wh")
        #expect(UsageFormatter.formatEnergy(0.999) == "999 Wh")

        // Greater than or equal to 1 kWh (formatted as kWh)
        #expect(UsageFormatter.formatEnergy(1.0) == "1 kWh")
        #expect(UsageFormatter.formatEnergy(1.52) == "1.5 kWh")
        #expect(UsageFormatter.formatEnergy(12.45) == "12 kWh")
    }

    @Test
    func cO2Formatting() {
        // Less than 1 kg (formatted as g)
        #expect(UsageFormatter.formatCO2(0.0015) == "1.5 g")
        #expect(UsageFormatter.formatCO2(0.0125) == "13 g")
        #expect(UsageFormatter.formatCO2(0.999) == "999 g")

        // Greater than or equal to 1 kg (formatted as kg)
        #expect(UsageFormatter.formatCO2(1.0) == "1 kg")
        #expect(UsageFormatter.formatCO2(1.52) == "1.5 kg")
        #expect(UsageFormatter.formatCO2(12.45) == "12 kg")
    }

    @Test
    func environmentalRowsKeepStableIdentityWhenTextMatches() {
        let duplicateText = "Today: 1.5 Wh (0 phone charges / 0 kettle boils)"
        let rows = [
            UsageMenuCardView.Model.EnvironmentalImpactLine(id: .energyToday, text: duplicateText),
            UsageMenuCardView.Model.EnvironmentalImpactLine(id: .energyWindow, text: duplicateText),
        ]

        #expect(rows.map(\.text) == [duplicateText, duplicateText])
        #expect(rows.map(\.id) == [.energyToday, .energyWindow])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
