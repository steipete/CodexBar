import Foundation

enum MiniMaxUsagePricing {
    struct Pricing: Equatable {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?

        init(
            inputCostPerToken: Double,
            outputCostPerToken: Double,
            cacheReadInputCostPerToken: Double,
            cacheCreationInputCostPerToken: Double = 0,
            thresholdTokens: Int? = nil,
            inputCostPerTokenAboveThreshold: Double? = nil,
            outputCostPerTokenAboveThreshold: Double? = nil,
            cacheReadInputCostPerTokenAboveThreshold: Double? = nil)
        {
            self.inputCostPerToken = inputCostPerToken
            self.outputCostPerToken = outputCostPerToken
            self.cacheReadInputCostPerToken = cacheReadInputCostPerToken
            self.cacheCreationInputCostPerToken = cacheCreationInputCostPerToken
            self.thresholdTokens = thresholdTokens
            self.inputCostPerTokenAboveThreshold = inputCostPerTokenAboveThreshold
            self.outputCostPerTokenAboveThreshold = outputCostPerTokenAboveThreshold
            self.cacheReadInputCostPerTokenAboveThreshold = cacheReadInputCostPerTokenAboveThreshold
        }
    }

    private static let perMillion = 1_000_000.0
    private static let longContextThreshold = 512_000

    private static let m27Standard = Pricing(
        inputCostPerToken: 0.30 / perMillion,
        outputCostPerToken: 1.20 / perMillion,
        cacheReadInputCostPerToken: 0.06 / perMillion,
        cacheCreationInputCostPerToken: 0.375 / perMillion)

    private static let m27Highspeed = Pricing(
        inputCostPerToken: 0.60 / perMillion,
        outputCostPerToken: 2.40 / perMillion,
        cacheReadInputCostPerToken: 0.06 / perMillion,
        cacheCreationInputCostPerToken: 0.375 / perMillion)

    private static let m25Legacy = Pricing(
        inputCostPerToken: 0.30 / perMillion,
        outputCostPerToken: 1.20 / perMillion,
        cacheReadInputCostPerToken: 0.03 / perMillion,
        cacheCreationInputCostPerToken: 0.375 / perMillion)

    private static let m3Standard = Pricing(
        inputCostPerToken: 0.30 / perMillion,
        outputCostPerToken: 1.20 / perMillion,
        cacheReadInputCostPerToken: 0.06 / perMillion,
        thresholdTokens: longContextThreshold,
        inputCostPerTokenAboveThreshold: 0.60 / perMillion,
        outputCostPerTokenAboveThreshold: 2.40 / perMillion,
        cacheReadInputCostPerTokenAboveThreshold: 0.12 / perMillion)

    private static let includedInPlan = Pricing(
        inputCostPerToken: 0,
        outputCostPerToken: 0,
        cacheReadInputCostPerToken: 0,
        cacheCreationInputCostPerToken: 0)

    static func minimaxCostUSD(
        model: String,
        inputToken: Int,
        cacheReadToken: Int,
        cacheCreateToken: Int,
        outputToken: Int) -> Double?
    {
        guard let pricing = self.pricing(for: model, inputToken: inputToken) else { return nil }
        return self.costUSD(
            pricing: pricing,
            inputToken: inputToken,
            cacheReadToken: cacheReadToken,
            cacheCreateToken: cacheCreateToken,
            outputToken: outputToken)
    }

    static func pricing(for model: String, inputToken: Int) -> Pricing? {
        let normalized = self.normalizeModel(model)
        if normalized.contains("coding-plan") {
            return self.includedInPlan
        }
        if normalized.contains("m3") {
            return self.m3Standard
        }
        if normalized.contains("m2.7"), normalized.contains("highspeed") {
            return self.m27Highspeed
        }
        if normalized.contains("m2.7") {
            return self.m27Standard
        }
        if normalized.contains("m2.5"), normalized.contains("highspeed") {
            return Pricing(
                inputCostPerToken: 0.60 / self.perMillion,
                outputCostPerToken: 2.40 / self.perMillion,
                cacheReadInputCostPerToken: 0.03 / self.perMillion,
                cacheCreationInputCostPerToken: 0.375 / self.perMillion)
        }
        if normalized.contains("m2.5") || normalized.contains("m2.1") || normalized == "m2" {
            return self.m25Legacy
        }
        if normalized.contains("m2") {
            return self.m25Legacy
        }
        return self.m27Standard
    }

    static func normalizeModel(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func costUSD(
        pricing: Pricing,
        inputToken: Int,
        cacheReadToken: Int,
        cacheCreateToken: Int,
        outputToken: Int) -> Double
    {
        let input = max(0, inputToken)
        let cached = min(max(0, cacheReadToken), input)
        let nonCached = max(0, input - cached)
        let cacheCreate = max(0, cacheCreateToken)
        let output = max(0, outputToken)

        let usesLongContext = pricing.thresholdTokens.map { input > $0 } ?? false
        let inputRate = usesLongContext
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let outputRate = usesLongContext
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken
        let cacheReadRate = usesLongContext
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken

        return (Double(nonCached) * inputRate)
            + (Double(cached) * cacheReadRate)
            + (Double(cacheCreate) * pricing.cacheCreationInputCostPerToken)
            + (Double(output) * outputRate)
    }
}
