import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexResetCreditExpiryNotifierTests {
    @Test
    func `posts one bounded summary without persisting or logging raw credit IDs`() throws {
        let defaults = InMemoryUserDefaults()
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let rawID = "private-provider-credit-id"
        var posts: [(prefix: String, title: String, body: String)] = []
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { prefix, title, body in
            posts.append((prefix, title, body))
        }
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [
                Self.credit(id: rawID, expiresAt: now.addingTimeInterval(86400)),
                Self.credit(id: "no-expiry-private-id", expiresAt: nil),
            ],
            availableCount: 2,
            updatedAt: now)

        notifier.postExpiringCreditsIfNeeded(snapshot: snapshot, resetStyle: .countdown, now: now)
        notifier.postExpiringCreditsIfNeeded(snapshot: snapshot, resetStyle: .countdown, now: now)

        #expect(posts.count == 1)
        #expect(posts[0].prefix == CodexResetCreditExpiryNotifier.notificationPrefix)
        #expect(posts[0].title == "Limit Reset Credits")
        #expect(posts[0].body == "1. Expires in 1d")
        #expect(!posts[0].prefix.contains(rawID))
        #expect(!posts[0].body.contains(rawID))
        let fingerprints = try #require(defaults.stringArray(
            forKey: CodexResetCreditExpiryNotifier.summaryFingerprintsKey))
        let fingerprint = try #require(fingerprints.first)
        #expect(fingerprints.count == 1)
        #expect(fingerprint.count == 64)
        #expect(!fingerprint.contains(rawID))
    }

    @Test
    func `switching account inventories does not repeat either notification`() {
        let defaults = InMemoryUserDefaults()
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        var postCount = 0
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { _, _, _ in
            postCount += 1
        }
        let firstAccount = CodexRateLimitResetCreditsSnapshot(
            credits: [Self.credit(id: "first-account-credit", expiresAt: now.addingTimeInterval(86400))],
            availableCount: 1,
            updatedAt: now)
        let secondAccount = CodexRateLimitResetCreditsSnapshot(
            credits: [Self.credit(id: "second-account-credit", expiresAt: now.addingTimeInterval(172_800))],
            availableCount: 1,
            updatedAt: now)

        notifier.postExpiringCreditsIfNeeded(snapshot: firstAccount, resetStyle: .countdown, now: now)
        notifier.postExpiringCreditsIfNeeded(snapshot: secondAccount, resetStyle: .countdown, now: now)
        notifier.postExpiringCreditsIfNeeded(snapshot: firstAccount, resetStyle: .countdown, now: now)
        notifier.postExpiringCreditsIfNeeded(snapshot: secondAccount, resetStyle: .countdown, now: now)

        #expect(postCount == 2)
        #expect(defaults.stringArray(forKey: CodexResetCreditExpiryNotifier.summaryFingerprintsKey)?.count == 2)
    }

    @Test
    func `no-expiry inventory does not trigger an expiry notification`() {
        let defaults = InMemoryUserDefaults()
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        var postCount = 0
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { _, _, _ in
            postCount += 1
        }

        notifier.postExpiringCreditsIfNeeded(
            snapshot: CodexRateLimitResetCreditsSnapshot(
                credits: [Self.credit(id: "no-expiry", expiresAt: nil)],
                availableCount: 1,
                updatedAt: now),
            resetStyle: .countdown,
            now: now)

        #expect(postCount == 0)
        #expect(defaults.stringArray(forKey: CodexResetCreditExpiryNotifier.summaryFingerprintsKey) == nil)
    }

    @Test
    func `countdowns supplement the existing summary without replacing its receipts`() throws {
        let defaults = InMemoryUserDefaults()
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [Self.credit(id: "synthetic-credit", expiresAt: expiry)], availableCount: 1, updatedAt: expiry)
        var prefixes: [String] = []
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { prefix, _, _ in
            prefixes.append(prefix)
        }
        notifier.postExpiringCreditsIfNeeded(
            snapshot: snapshot, resetStyle: .countdown, now: expiry.addingTimeInterval(-3 * 86400))
        let summaryReceipts = try #require(defaults.stringArray(
            forKey: CodexResetCreditExpiryNotifier.summaryFingerprintsKey))
        // Frozen legacy receipt includes the credit model's existing stable-ID hashing.
        #expect(summaryReceipts == ["a20b7ea82351883fddce8ebb9cc2763dc2b440e148a1b91fd447723fa739205e"])
        for remaining in [86400.0, 86300, 43200, 3600, 3599, 1800, 600, 0, -1] {
            // Recreate the notifier to verify that reminders use persisted receipts, including after a restart.
            CodexResetCreditExpiryNotifier(userDefaults: defaults) { prefix, _, _ in prefixes.append(prefix) }
                .postExpiringCreditsIfNeeded(
                    snapshot: snapshot,
                    countdownEnabled: true,
                    resetStyle: .countdown,
                    now: expiry.addingTimeInterval(-remaining))
        }
        #expect(prefixes == [
            CodexResetCreditExpiryNotifier.notificationPrefix,
            CodexResetCreditExpiryNotifier.countdownNotificationPrefix,
            CodexResetCreditExpiryNotifier.countdownNotificationPrefix,
        ])
        let receipts = try #require(defaults.stringArray(forKey: CodexResetCreditExpiryNotifier.summaryFingerprintsKey))
        #expect(summaryReceipts.allSatisfy(receipts.contains))
        #expect(receipts.allSatisfy { $0.count == 64 && !$0.contains("synthetic-credit") })
    }

    @Test
    func `late first observation sends one notice and consumes earlier countdown stages`() {
        let defaults = InMemoryUserDefaults()
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [Self.credit(id: "late", expiresAt: expiry)], availableCount: 1, updatedAt: expiry)
        var posts = 0
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { _, _, _ in posts += 1 }
        for remaining in [1800.0, 1700, 7200, 1600] {
            notifier.postExpiringCreditsIfNeeded(
                snapshot: snapshot,
                countdownEnabled: true,
                resetStyle: .countdown,
                now: expiry.addingTimeInterval(-remaining))
        }
        #expect(posts == 1)
    }

    @Test
    func `countdown opt out leaves receipts available and credit display does not gate opt in`() {
        let defaults = InMemoryUserDefaults()
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [Self.credit(id: "opt-in", expiresAt: expiry)], availableCount: 1, updatedAt: expiry)
        var posts = 0
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { _, _, _ in posts += 1 }
        let now = expiry.addingTimeInterval(-3600)
        notifier.postExpiringCreditsIfNeeded(
            snapshot: snapshot, summaryEnabled: false, resetStyle: .countdown, now: now)
        #expect(posts == 0)
        #expect(defaults.object(forKey: CodexResetCreditExpiryNotifier.summaryFingerprintsKey) == nil)
        notifier.postExpiringCreditsIfNeeded(
            snapshot: snapshot, summaryEnabled: false, countdownEnabled: true, resetStyle: .countdown, now: now)
        notifier.postExpiringCreditsIfNeeded(
            snapshot: snapshot, summaryEnabled: false, countdownEnabled: true, resetStyle: .countdown, now: now)
        #expect(posts == 1)
    }

    private static func credit(id: String, expiresAt: Date?) -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: .available,
            grantedAt: Date(timeIntervalSince1970: 1_781_700_000),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }
}
