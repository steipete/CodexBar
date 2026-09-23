import Foundation

/// Display scale for the Codex extra-credits bar and menu-bar icon fill.
///
/// OpenAI often reports a remaining balance without a pack `limit`. A hardcoded 1000-credit
/// cap then clamps any larger pile to 100% full. Auto keeps that historical floor when
/// remaining is at or below 1000, and otherwise uses the next 1000-credit bucket so the
/// bar can move while the balance is still well above 1000.
public struct CreditsBarScale: Equatable, Sendable {
    public static let minimum: Double = 1000

    public let scale: Double
    public let remainingPercent: Double

    public init(scale: Double, remainingPercent: Double) {
        self.scale = scale
        self.remainingPercent = min(100, max(0, remainingPercent))
    }

    public static func display(from credits: CreditsSnapshot?) -> Self? {
        guard let credits, credits.hasWorkspaceBalance != true else { return nil }
        if let limit = credits.codexCreditLimit, limit.limit > 0 {
            return Self(scale: limit.limit, remainingPercent: limit.remainingPercent)
        }
        guard let remaining = credits.displayRemaining else { return nil }
        return Self.auto(remaining: remaining)
    }

    public static func auto(remaining: Double) -> Self {
        let scale = self.autoScale(for: remaining)
        return Self(scale: scale, remainingPercent: self.remainingPercent(remaining: remaining, scale: scale))
    }

    public static func autoScale(for remaining: Double) -> Double {
        guard remaining.isFinite, remaining > self.minimum else { return self.minimum }
        return (remaining / self.minimum).rounded(.up) * self.minimum
    }

    public static func remainingPercent(remaining: Double, scale: Double? = nil, limit: Double? = nil) -> Double {
        if let limit, limit.isFinite, limit > 0 {
            return self.clampedRatio(remaining: remaining, scale: limit)
        }
        let resolvedScale = scale ?? self.autoScale(for: remaining)
        return Self.clampedRatio(remaining: remaining, scale: resolvedScale)
    }

    private static func clampedRatio(remaining: Double, scale: Double) -> Double {
        guard remaining.isFinite, scale.isFinite, scale > 0 else { return 0 }
        return min(100, max(0, remaining / scale * 100))
    }
}
