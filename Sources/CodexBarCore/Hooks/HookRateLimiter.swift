import Foundation

/// In-memory storm suppression: fire a given (event, provider, account, window)
/// at most once per `window` seconds. Quota events already dedupe upstream via
/// CodexBar's threshold/depletion/reset state; this is a backstop for
/// `provider_unavailable` / `refresh_failed`, which can otherwise repeat every
/// refresh while an outage persists. In-memory only: the state resets on relaunch.
public actor HookRateLimiter {
    public static let defaultWindow: TimeInterval = 600 // 10 minutes

    private var lastFired: [String: Date] = [:]
    private let window: TimeInterval

    public init(window: TimeInterval = HookRateLimiter.defaultWindow) {
        self.window = window
    }

    /// Records a fire for `event` at `now` and returns whether it is allowed
    /// (i.e. no matching fire within the window). Call once per candidate dispatch.
    public func allow(_ event: HookEvent, now: Date = Date()) -> Bool {
        let key = Self.key(for: event)
        if let previous = self.lastFired[key], now.timeIntervalSince(previous) < self.window {
            return false
        }
        self.lastFired[key] = now
        return true
    }

    static func key(for event: HookEvent) -> String {
        [
            event.event.rawValue,
            event.provider,
            event.account ?? "",
            event.window ?? "",
        ].joined(separator: "\u{1F}")
    }
}
