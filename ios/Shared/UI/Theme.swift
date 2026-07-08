import SwiftUI

extension Color {
    /// Hex string like "10A37F" or "#10A37F" (RGB) / "AARRGGBB".
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 8:
            (a, r, g, b) = (value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default:
            (a, r, g, b) = (255, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255)
    }
}

/// Visual identity for a provider, derived from the shared model.
struct ProviderVisuals {
    let provider: UsageProvider

    var accent: Color { Color(hex: self.provider.accentHex) }
    var displayName: String { self.provider.displayName }
    var iconAssetName: String? { self.provider.iconAssetName }

    /// SF Symbol fallback when no bundled vector icon exists.
    var fallbackSymbol: String { "cpu" }
}

/// Maps a remaining-percent value to a semantic color: green when plenty is left, amber when
/// getting low, red when nearly exhausted.
enum UsageTone {
    static func color(remainingPercent: Double?) -> Color {
        guard let remaining = remainingPercent else { return .secondary }
        switch remaining {
        case ..<10: return Color(hex: "FF3B30")
        case ..<25: return Color(hex: "FF9F0A")
        default: return Color(hex: "30D158")
        }
    }
}

/// Shared numeric formatting.
enum UsageFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func currency(_ value: Double?, code: String) -> String? {
        guard let value else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = value < 10 ? 2 : 0
        return formatter.string(from: NSNumber(value: value))
    }

    static func tokens(_ value: Int?) -> String? {
        guard let value else { return nil }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
