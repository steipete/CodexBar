import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexResetCreditExpiryNotifierTests {
    @Test
    func `posts once for available credits expiring within three days`() throws {
        let defaults = try #require(UserDefaults(suiteName: "CodexResetCreditExpiryNotifierTests"))
        defaults.removeObject(forKey: "codexResetCreditExpiryNotificationsPosted")
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        var posted: [(String, String, String)] = []
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { id, title, body in
            posted.append((id, title, body))
        }
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [
                Self.credit(id: "soon", status: .available, expiresAt: now.addingTimeInterval(2 * 24 * 60 * 60)),
                Self.credit(id: "later", status: .available, expiresAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
                Self.credit(id: "used", status: .redeemed, expiresAt: now.addingTimeInterval(1 * 24 * 60 * 60)),
            ],
            availableCount: 2,
            updatedAt: now)

        notifier.postExpiringCreditsIfNeeded(snapshot: snapshot, now: now)
        notifier.postExpiringCreditsIfNeeded(snapshot: snapshot, now: now)

        #expect(posted.map(\.0) == ["codex-reset-credit-expiring-soon"])
        #expect(defaults.stringArray(forKey: "codexResetCreditExpiryNotificationsPosted") == ["soon"])
    }

    private static func credit(
        id: String,
        status: CodexRateLimitResetCreditStatus,
        expiresAt: Date) -> CodexRateLimitResetCredit
    {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: status,
            grantedAt: expiresAt.addingTimeInterval(-7 * 24 * 60 * 60),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: "Reset",
            description: nil)
    }
}
