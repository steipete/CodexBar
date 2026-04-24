import CodexBarCore
import Foundation

extension Notification.Name {
    static let codexbarOpenSettings = Notification.Name("codexbarOpenSettings")
    static let codexbarDebugBlinkNow = Notification.Name("codexbarDebugBlinkNow")
    static let codexbarWeeklyLimitReset = Notification.Name("codexbarWeeklyLimitReset")
    static let codexbarProviderConfigDidChange = Notification.Name("codexbarProviderConfigDidChange")
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
