import CodexBarCore
import Foundation

enum MenuBarDisplayText {
    static func percentText(window: RateWindow?, showUsed: Bool) -> String? {
        guard let window else { return nil }
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        let clamped = min(100, max(0, percent))
        return String(format: "%.0f%%", clamped)
    }

    static func paceText(
        provider: UsageProvider,
        window: RateWindow?,
        now: Date = .init(),
        profile: UsagePaceProfile? = nil) -> String?
    {
        guard let window else { return nil }
        guard let pace = UsagePaceText.weeklyPace(provider: provider, window: window, now: now, profile: profile)
        else {
            return nil
        }
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
        now: Date = .init(),
        paceProfile: UsagePaceProfile? = nil) -> String?
    {
        switch mode {
        case .percent:
            return self.percentText(window: percentWindow, showUsed: showUsed)
        case .pace:
            return self.paceText(provider: provider, window: paceWindow, now: now, profile: paceProfile)
        case .both:
            guard let percent = percentText(window: percentWindow, showUsed: showUsed) else { return nil }
            guard let pace = Self.paceText(provider: provider, window: paceWindow, now: now, profile: paceProfile)
            else {
                return nil
            }
            return "\(percent) · \(pace)"
        }
    }
}
