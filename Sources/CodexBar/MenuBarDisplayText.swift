import CodexBarCore
import Foundation

enum MenuBarDisplayText {
    /// Returns a compact countdown string (e.g. "28m" or "2h 5m") until the next quota reset.
    /// Returns nil if `resetsAt` is nil or already in the past.
    static func timeUntilResetText(resetsAt: Date?, now: Date = .init()) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }
        let totalSeconds = Int(resetsAt.timeIntervalSince(now))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return minutes > 0 ? "\(minutes)m" : "<1m"
        }
    }

    static func percentText(window: RateWindow?, showUsed: Bool) -> String? {
        guard let window else { return nil }
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        let clamped = min(100, max(0, percent))
        return String(format: "%.0f%%", clamped)
    }

    static func paceText(provider: UsageProvider, window: RateWindow?, now: Date = .init()) -> String? {
        guard let window else { return nil }
        guard let pace = UsagePaceText.weeklyPace(provider: provider, window: window, now: now) else { return nil }
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        let sign = pace.deltaPercent >= 0 ? "+" : "-"
        return "\(sign)\(deltaValue)%"
    }

    static func displayText(
        mode: MenuBarDisplayMode,
        provider: UsageProvider,
        percentWindow: RateWindow?,
        paceWindow: RateWindow?,
        showUsed: Bool,
        now: Date = .init()) -> String?
    {
        switch mode {
        case .percent:
            return self.percentText(window: percentWindow, showUsed: showUsed)
        case .pace:
            return self.paceText(provider: provider, window: paceWindow, now: now)
        case .both:
            guard let percent = percentText(window: percentWindow, showUsed: showUsed) else { return nil }
            guard let pace = Self.paceText(provider: provider, window: paceWindow, now: now) else { return nil }
            return "\(percent) · \(pace)"
        }
    }
}
