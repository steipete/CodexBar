import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct EnvironmentalImpactTests {
    @Test
    func environmentalImpactCalculations() {
        // 100,000 tokens
        // Joules = 100,000 * 12 = 1,200,000 J
        // kWh = 1,200,000 / 3,600,000 = 0.3333... kWh
        // CO2 kg = 0.3333... * 0.385 = 0.12833... kg (128.33... g)
        let impact = EnvironmentalImpact(tokens: 100_000)

        #expect(abs(impact.energyKWh - 0.333333) < 0.0001)
        #expect(abs(impact.co2Kg - 0.128333) < 0.0001)

        // charges = 0.3333... * 75 = 25
        #expect(impact.smartphoneCharges == 25)

        // kettles = 0.3333... * 10 = 3.33 -> round -> 3
        #expect(impact.boiledKettles == 3)

        // carKm = 0.128333... / 0.12 = 1.0694...
        #expect(abs(impact.carKm - 1.0694) < 0.001)
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
}
