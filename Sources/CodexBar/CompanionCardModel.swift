import Foundation
import SwiftUI

public struct CompanionCardModel: Codable, Identifiable {
    public struct Metric: Codable, Identifiable {
        public let id: String
        public let title: String
        public let percent: Double
        public let percentLabel: String
        public let accessibilityLabel: String
        public let statusText: String?
        public let resetText: String?
        public let detailText: String?
        public let detailLeftText: String?
        public let detailRightText: String?
        public let pacePercent: Double?
        public let paceOnTop: Bool
        public let warningMarkerPercents: [Double]
        public let cardStyle: Bool
    }
    
    public struct TokenUsageSection: Codable {
        public let sessionLine: String
        public let monthLine: String
        public let hintLine: String?
        public let errorLine: String?
        public let errorCopyText: String?
    }
    
    public struct ProviderCostSection: Codable {
        public let title: String
        public let percentUsed: Double?
        public let spendLine: String
        public let percentLine: String?
    }
    
    public let providerName: String
    public var id: String { providerName }
    public let email: String
    public let subtitleText: String
    public let subtitleIsError: Bool
    public let planText: String?
    public let metrics: [Metric]
    public let usageNotes: [String]
    public let creditsText: String?
    public let creditsRemaining: Double?
    public let creditsHintText: String?
    public let creditsHintCopyText: String?
    public let providerCost: ProviderCostSection?
    public let tokenUsage: TokenUsageSection?
    public let placeholder: String?
    public let progressColorHex: String
    public let updatedAt: Date
    
    public var progressColor: Color {
        Color(hex: progressColorHex) ?? .blue
    }

    /// A card is worth showing if it carries any real content — not just non-empty
    /// quota metrics. Cost-only, note-only, credits-only, or placeholder/error cards count.
    public var hasDisplayableContent: Bool {
        !metrics.isEmpty
            || providerCost != nil
            || tokenUsage != nil
            || creditsText != nil
            || !usageNotes.isEmpty
            || placeholder != nil
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0

        let length = hexSanitized.count

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0

        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0

        } else {
            return nil
        }

        self.init(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }
}
