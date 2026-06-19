import Foundation

public struct EnvironmentalImpact: Sendable, Equatable {
    private enum Estimate {
        static let joulesPerKWh = 3_600_000.0
        static let globalAverageCO2KgPerKWh = 0.385
        static let smartphoneChargesPerKWh = 75.0
        static let kettleBoilsPerKWh = 10.0
        static let averageCarCO2KgPerKm = 0.12
    }

    public let energyKWh: Double
    public let co2Kg: Double

    /// Fallback footprint for unknown models (conservative)
    public static let fallbackJoulesPerToken = 10.0

    /// Literature-based footprints (in Joules per Token)
    public static func joulesPerToken(provider: UsageProvider, modelName: String) -> Double? {
        let name = modelName.lowercased()

        switch provider {
        case .gemini, .vertexai:
            // Google Methodology (e.g. Gemini apps prompt ~ 0.3 Wh ~ 1080 J for typical prompt, translates to ~ 10-30
            // J/token)
            if name.contains("pro") || name.contains("ultra") {
                return 25.0
            } else if name.contains("flash") || name.contains("haiku") {
                return 5.0
            } else {
                return 15.0
            }
        case .mistral:
            // Mistral LCA: Le Chat 400-token output = 1.14g CO2e ~ 26.6 J/token for Large 2
            if name.contains("large") {
                return 26.6
            } else if name.contains("small") || name.contains("nemo") || name.contains("ministral") {
                return 10.0
            } else if name.contains("8x22b") {
                return 20.0
            } else if name.contains("8x7b") || name.contains("7b") {
                return 5.0
            } else {
                return 15.0
            }
        case .claude, .bedrock:
            // Claude/Bedrock footprints
            if name.contains("opus") {
                return 30.0
            } else if name.contains("sonnet") {
                return 15.0
            } else if name.contains("haiku") {
                return 5.0
            } else {
                return 15.0
            }
        case .openai, .azureopenai, .codex:
            // OpenAI MLCommons power measurements context
            if name.contains("gpt-4o-mini") || name.contains("gpt-3.5") || name.contains("text-embedding") {
                return 5.0
            } else if name.contains("gpt-4") || name.contains("o1") || name.contains("o3") {
                return 25.0
            } else {
                return 15.0
            }
        default:
            return nil
        }
    }

    public init?(provider: UsageProvider, breakdowns: [CostUsageDailyReport.ModelBreakdown]) {
        guard !breakdowns.isEmpty else { return nil }
        var totalJoules = 0.0
        var hasValidTokens = false

        for breakdown in breakdowns {
            guard let tokens = breakdown.totalTokens, tokens > 0 else { continue }
            hasValidTokens = true
            let footprint = Self.joulesPerToken(provider: provider, modelName: breakdown.modelName) ?? Self
                .fallbackJoulesPerToken
            totalJoules += Double(tokens) * footprint
        }

        guard hasValidTokens else { return nil }

        self.energyKWh = totalJoules / Estimate.joulesPerKWh
        self.co2Kg = self.energyKWh * Estimate.globalAverageCO2KgPerKWh
    }

    public var smartphoneCharges: Int {
        Int(round(self.energyKWh * Estimate.smartphoneChargesPerKWh))
    }

    public var kettleBoils: Int {
        Int(round(self.energyKWh * Estimate.kettleBoilsPerKWh))
    }

    public var carKm: Double {
        self.co2Kg / Estimate.averageCarCO2KgPerKm
    }
}
