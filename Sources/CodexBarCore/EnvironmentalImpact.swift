import Foundation

public struct EnvironmentalImpact: Sendable, Equatable {
    public let energyKWh: Double
    public let co2Kg: Double

    public init(tokens: Int) {
        // Based on typical estimates: 12 Joules per token
        // Energy in Joules = tokens * 12
        // Energy in kWh = Joules / 3,600,000
        let joules = Double(tokens) * 12.0
        self.energyKWh = joules / 3_600_000.0

        // Based on global average grid carbon intensity: 385 g CO2e per kWh
        self.co2Kg = self.energyKWh * 0.385
    }

    public var smartphoneCharges: Int {
        // 1 kWh = ~75 smartphone charges (assuming typical ~13Wh battery and charge efficiency)
        Int(round(self.energyKWh * 75.0))
    }

    public var boiledKettles: Int {
        // 1 kWh = ~10 boiled kettles of water (assuming 1 liter of water boiled using a 2000W kettle for ~3 minutes)
        Int(round(self.energyKWh * 10.0))
    }

    public var carKm: Double {
        // ~120g CO2 per km of driving an average gasoline car = 0.12 kg CO2 per km
        // km = co2Kg / 0.12
        self.co2Kg / 0.12
    }
}
