import Foundation

/// Display scale for the Codex extra-credits bar and menu-bar icon fill.
///
/// OpenAI often reports a remaining balance without a pack `limit`. A hardcoded 1000-credit
/// cap then clamps any larger pile to 100% full. Auto keeps that historical floor when
/// remaining is at or below 1000, and otherwise uses the next 1000-credit bucket so the
/// bar can move while the balance is still well above 1000.
///
/// Re-bucketing from the current remaining on every refresh refills the bar at thousand-credit
/// boundaries (2001 → 66.7% of 3000, then 2000 → 100% of 2000). `HighWater` keeps the automatic
/// reference stable while credits are consumed, and raises it when remaining implies a larger
/// bucket (purchase or first observation).
///
/// First iteration is process-session only: not persisted across launches, and production uses
/// one default account key so the menu and icon share a reference. A restart re-buckets from
/// the current remaining. Workspace balances stay numeric-only; a reported `codexCreditLimit`
/// still wins over Auto.
public struct CreditsBarScale: Equatable, Sendable {
    public static let minimum: Double = 1000

    /// Injected automatic reference for the current menu/icon render.
    /// Tests pass a fresh `HighWater`; production binds `HighWater.session`.
    @TaskLocal public static var highWater: HighWater?

    public let scale: Double
    public let remainingPercent: Double

    public init(scale: Double, remainingPercent: Double) {
        self.scale = scale
        self.remainingPercent = min(100, max(0, remainingPercent))
    }

    public static func display(
        from credits: CreditsSnapshot?,
        highWater: HighWater? = nil,
        accountKey: String = HighWater.defaultAccountKey) -> Self?
    {
        guard let credits, credits.hasWorkspaceBalance != true else { return nil }
        if let limit = credits.codexCreditLimit, limit.limit > 0 {
            return Self(scale: limit.limit, remainingPercent: limit.remainingPercent)
        }
        guard let remaining = credits.displayRemaining else { return nil }
        guard let store = highWater ?? Self.highWater else {
            return Self.auto(remaining: remaining)
        }
        let scale = store.observe(remaining: remaining, accountKey: accountKey)
        return Self(scale: scale, remainingPercent: self.remainingPercent(remaining: remaining, scale: scale))
    }

    public static func auto(remaining: Double) -> Self {
        let scale = self.autoScale(for: remaining)
        return Self(scale: scale, remainingPercent: self.remainingPercent(remaining: remaining, scale: scale))
    }

    /// Stateless next-thousand bucket. Callers that need depletion-stable Auto should observe
    /// through `HighWater` or `sessionScale(for:)`.
    public static func autoScale(for remaining: Double) -> Double {
        guard remaining.isFinite, remaining > self.minimum else { return self.minimum }
        return (remaining / self.minimum).rounded(.up) * self.minimum
    }

    /// Process-session Auto scale used by the menu-bar icon and view fallbacks.
    /// Prefers the task-local store so tests stay isolated from `HighWater.session`.
    public static func sessionScale(
        for remaining: Double,
        accountKey: String = HighWater.defaultAccountKey) -> Double
    {
        (self.highWater ?? HighWater.session).observe(remaining: remaining, accountKey: accountKey)
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

extension CreditsBarScale {
    /// Account-keyed high-water for the automatic extra-credits scale.
    ///
    /// Observe raises the stored bucket; depletion never lowers it. Purchases and resets that
    /// increase remaining raise the reference on the next observation. This object is in-memory
    /// only — persist per account if Auto must survive relaunch.
    public final class HighWater: @unchecked Sendable {
        public static let session = HighWater()
        public static let defaultAccountKey = "codex.personal"

        private let lock = NSLock()
        private var scaleByAccount: [String: Double] = [:]

        public init() {}

        public func observe(
            remaining: Double,
            accountKey: String = HighWater.defaultAccountKey) -> Double
        {
            let bucket = CreditsBarScale.autoScale(for: remaining)
            self.lock.lock()
            defer { self.lock.unlock() }
            let scale = max(self.scaleByAccount[accountKey] ?? CreditsBarScale.minimum, bucket)
            self.scaleByAccount[accountKey] = scale
            return scale
        }

        public func reset() {
            self.lock.lock()
            self.scaleByAccount.removeAll()
            self.lock.unlock()
        }
    }
}
