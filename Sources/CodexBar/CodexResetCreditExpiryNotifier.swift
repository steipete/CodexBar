import CodexBarCore
import Foundation

@MainActor
struct CodexResetCreditExpiryNotifier {
    static let expiryWindow: TimeInterval = 3 * 24 * 60 * 60

    var userDefaults: UserDefaults = .standard
    var notificationPoster: (String, String, String) -> Void = { id, title, body in
        AppNotifications.shared.post(idPrefix: id, title: title, body: body)
    }

    func postExpiringCreditsIfNeeded(snapshot: CodexRateLimitResetCreditsSnapshot, now: Date = Date()) {
        let key = "codexResetCreditExpiryNotificationsPosted"
        var posted = Set(self.userDefaults.stringArray(forKey: key) ?? [])
        var changed = false

        for credit in snapshot.credits {
            guard credit.status == .available,
                  let expiresAt = credit.expiresAt,
                  expiresAt > now,
                  expiresAt.timeIntervalSince(now) <= Self.expiryWindow,
                  !posted.contains(credit.id)
            else {
                continue
            }

            posted.insert(credit.id)
            changed = true
            self.notificationPoster(
                "codex-reset-credit-expiring-\(credit.id)",
                L("Codex reset expires soon"),
                String(
                    format: L("A Codex reset credit expires %@."),
                    UsageFormatter.resetDescription(from: expiresAt, now: now)))
        }

        if changed {
            self.userDefaults.set(Array(posted).sorted(), forKey: key)
        }
    }
}
