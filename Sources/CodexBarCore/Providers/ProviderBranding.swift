import Foundation

public struct ProviderColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct ProviderBranding: Sendable {
    public let iconStyle: IconStyle
    public let iconResourceName: String
    public let color: ProviderColor

    public init(iconStyle: IconStyle, iconResourceName: String, color: ProviderColor) {
        self.iconStyle = iconStyle
        self.iconResourceName = iconResourceName
        self.color = color
    }
}
