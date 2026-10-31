import CodexBarCore
import CryptoKit
import Foundation

@MainActor
struct CodexResetCreditExpiryNotifier {
    static let expiryWindow: TimeInterval = 3 * 24 * 60 * 60
    static let notificationPrefix = "codex-reset-credit-expiry"
    static let countdownNotificationPrefix = "codex-reset-credit-countdown"
    static let summaryFingerprintsKey = "codexResetCreditExpirySummaryFingerprints"
    static let maximumRememberedSummaries = 192
    private static let reminderThresholds: [TimeInterval] = [86400, 3600]

    var userDefaults: UserDefaults = .standard
    var notificationPoster: (String, String, String) -> Void = { prefix, title, body in
        AppNotifications.shared.post(idPrefix: prefix, title: title, body: body)
    }

    func postExpiringCreditsIfNeeded(
        snapshot: CodexRateLimitResetCreditsSnapshot,
        summaryEnabled: Bool = true,
        countdownEnabled: Bool = false,
        resetStyle: ResetTimeDisplayStyle,
        now: Date = Date())
    {
        guard summaryEnabled || countdownEnabled else { return }
        let expiringCredits = snapshot.availableInventory(at: now).credits.filter { credit in
            guard let expiresAt = credit.expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= Self.expiryWindow
        }
        guard !expiringCredits.isEmpty else { return }

        let fingerprint = Self.summaryFingerprint(expiringCredits)
        var notifiedFingerprints = self.userDefaults.stringArray(forKey: Self.summaryFingerprintsKey) ?? []
        let sendsSummary = summaryEnabled && !notifiedFingerprints.contains(fingerprint)
        var reminders: [CodexRateLimitResetCredit] = []
        if countdownEnabled {
            for credit in expiringCredits {
                guard let expiresAt = credit.expiresAt,
                      let threshold = Self.reminderThresholds.last(where: { expiresAt.timeIntervalSince(now) <= $0 })
                else { continue }
                let receipt = Self.summaryFingerprint([credit], threshold: threshold)
                guard !notifiedFingerprints.contains(receipt) else { continue }
                reminders.append(credit)
                // A late first refresh consumes earlier stages too, so they cannot arrive after the last call.
                for stage in Self.reminderThresholds where stage >= threshold {
                    let receipt = Self.summaryFingerprint([credit], threshold: stage)
                    if !notifiedFingerprints.contains(receipt) { notifiedFingerprints.append(receipt) }
                }
            }
        }
        let creditsToPost = sendsSummary ? expiringCredits : reminders
        guard !creditsToPost.isEmpty else { return }
        if sendsSummary { notifiedFingerprints.append(fingerprint) }
        if notifiedFingerprints.count > Self.maximumRememberedSummaries {
            notifiedFingerprints.removeFirst(notifiedFingerprints.count - Self.maximumRememberedSummaries)
        }
        self.userDefaults.set(notifiedFingerprints, forKey: Self.summaryFingerprintsKey)

        let expiringSnapshot = CodexRateLimitResetCreditsSnapshot(
            credits: creditsToPost,
            availableCount: creditsToPost.count,
            updatedAt: now)
        guard let presentation = LimitResetCreditsPresentation.make(
            snapshot: expiringSnapshot,
            resetStyle: resetStyle,
            now: now)
        else {
            return
        }
        self.notificationPoster(
            sendsSummary ? Self.notificationPrefix : Self.countdownNotificationPrefix,
            L("Limit Reset Credits"),
            presentation.helpText)
    }

    private static func summaryFingerprint(
        _ credits: [CodexRateLimitResetCredit],
        threshold: TimeInterval? = nil) -> String
    {
        let material = credits.map { credit in
            "\(credit.id)\u{1f}\(credit.expiresAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\u{1e}") + (threshold.map { "\u{1f}\($0)" } ?? "")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
