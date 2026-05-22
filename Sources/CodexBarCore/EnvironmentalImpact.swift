import Foundation

public struct EnvironmentalImpact: Sendable, Equatable {
    private enum Estimate {
        static let joulesPerToken = 12.0
        static let joulesPerKWh = 3_600_000.0
        static let globalAverageCO2KgPerKWh = 0.385
        static let smartphoneChargesPerKWh = 75.0
        static let kettleBoilsPerKWh = 10.0
        static let averageCarCO2KgPerKm = 0.12
    }

    public let energyKWh: Double
    public let co2Kg: Double

    public init(tokens: Int) {
        // Broad estimate only; real usage varies by model, hardware, batching, and grid mix.
        let joules = Double(tokens) * Estimate.joulesPerToken
        self.energyKWh = joules / Estimate.joulesPerKWh

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
