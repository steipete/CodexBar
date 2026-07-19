import Foundation

public struct UsageChartScale: Equatable, Sendable {
    public let maximum: Double

    public init(values: [Double]) {
        self.maximum = values
            .filter { $0.isFinite && $0 > 0 }
            .max() ?? 0
    }

    public func fraction(for value: Double) -> Double {
        guard self.maximum > 0, value.isFinite, value > 0 else { return 0 }
        return min(value / self.maximum, 1)
    }
}
