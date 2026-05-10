import CodexBarCore
import Foundation

extension Notification.Name {
    static let codexbarOpenSettings = Notification.Name("codexbarOpenSettings")
    static let codexbarDebugBlinkNow = Notification.Name("codexbarDebugBlinkNow")
    static let codexbarWeeklyLimitReset = Notification.Name("codexbarWeeklyLimitReset")
    static let codexbarProviderConfigDidChange = Notification.Name("codexbarProviderConfigDidChange")
    static let codexbarQuotaWarningDidPost = Notification.Name("codexbarQuotaWarningDidPost")
}

@MainActor
final class WeeklyLimitResetEvent: NSObject {
    let provider: UsageProvider
    let accountIdentifier: String
    let accountLabel: String?
    let usedPercent: Double

    init(provider: UsageProvider, accountIdentifier: String, accountLabel: String?, usedPercent: Double) {
        self.provider = provider
        self.accountIdentifier = accountIdentifier
        self.accountLabel = accountLabel
        self.usedPercent = usedPercent
    }
}

@MainActor
final class QuotaWarningPostedEvent: NSObject {
    let provider: UsageProvider
    let window: QuotaWarningWindow
    let threshold: Int
    let postedAt: Date

    init(provider: UsageProvider, window: QuotaWarningWindow, threshold: Int, postedAt: Date) {
        self.provider = provider
        self.window = window
        self.threshold = threshold
        self.postedAt = postedAt
    }
}
