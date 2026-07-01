import CodexBarCore
import CryptoKit
import Foundation

@MainActor
struct CodexResetCreditExpiryNotifier {
    static let expiryWindow: TimeInterval = 3 * 24 * 60 * 60
    static let notificationPrefix = "codex-reset-credit-expiry"
    static let summaryFingerprintKey = "codexResetCreditExpirySummaryFingerprint"

    var userDefaults: UserDefaults = .standard
    var notificationPoster: (String, String, String) -> Void = { prefix, title, body in
        AppNotifications.shared.post(idPrefix: prefix, title: title, body: body)
    }

    func postExpiringCreditsIfNeeded(
        snapshot: CodexRateLimitResetCreditsSnapshot,
        resetStyle: ResetTimeDisplayStyle,
        now: Date = Date())
    {
        let expiringCredits = snapshot.availableInventory(at: now).credits.filter { credit in
            guard let expiresAt = credit.expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= Self.expiryWindow
        }
        guard !expiringCredits.isEmpty else { return }

        let fingerprint = Self.summaryFingerprint(expiringCredits)
        guard self.userDefaults.string(forKey: Self.summaryFingerprintKey) != fingerprint else { return }
        self.userDefaults.set(fingerprint, forKey: Self.summaryFingerprintKey)

        let expiringSnapshot = CodexRateLimitResetCreditsSnapshot(
            credits: expiringCredits,
            availableCount: expiringCredits.count,
            updatedAt: now)
        guard let presentation = CodexResetCreditsPresentation.make(
            snapshot: expiringSnapshot,
            resetStyle: resetStyle,
            now: now)
        else {
            return
        }
        self.notificationPoster(
            Self.notificationPrefix,
            L("Limit Reset Credits"),
            presentation.helpText)
    }

    private static func summaryFingerprint(_ credits: [CodexRateLimitResetCredit]) -> String {
        let material = credits.map { credit in
            "\(credit.id)\u{1f}\(credit.expiresAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
