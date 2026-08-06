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

    public init(hex: UInt32) {
        precondition(hex <= 0xFFFFFF, "Provider colors must use a six-digit RGB hex value.")
        self.red = Double((hex >> 16) & 0xFF) / 255
        self.green = Double((hex >> 8) & 0xFF) / 255
        self.blue = Double(hex & 0xFF) / 255
    }
}

public struct ProviderBranding: Sendable {
    public enum ProgressColorStyle: Sendable {
        case brand
        case label
    }

    public let iconStyle: IconStyle
    public let iconResourceName: String
    public let color: ProviderColor
    public let widgetColor: ProviderColor
    public let burnDownWidgetColor: ProviderColor
    public let confettiPalette: [ProviderColor]
    public let progressColorStyle: ProgressColorStyle

    /// Source-compatible fallback for external CodexBarCore clients. Registered descriptors must provide
    /// a curated palette; registry tests reject this duplicated-color fallback.
    @available(*, deprecated, message: "Provide a curated 2–3-color confettiPalette.")
    public init(iconStyle: IconStyle, iconResourceName: String, color: ProviderColor) {
        self.init(
            iconStyle: iconStyle,
            iconResourceName: iconResourceName,
            color: color,
            confettiPalette: [color, color])
    }

    public init(
        iconStyle: IconStyle,
        iconResourceName: String,
        color: ProviderColor,
        confettiPalette: [ProviderColor],
        widgetColor: ProviderColor? = nil,
        burnDownWidgetColor: ProviderColor = ProviderColor(red: 0.60, green: 0.60, blue: 0.60),
        progressColorStyle: ProgressColorStyle = .brand)
    {
        precondition((2...3).contains(confettiPalette.count), "Provider confetti palettes require 2–3 colors.")
        self.iconStyle = iconStyle
        self.iconResourceName = iconResourceName
        self.color = color
        self.widgetColor = widgetColor ?? color
        self.burnDownWidgetColor = burnDownWidgetColor
        self.confettiPalette = confettiPalette
        self.progressColorStyle = progressColorStyle
    }
}
