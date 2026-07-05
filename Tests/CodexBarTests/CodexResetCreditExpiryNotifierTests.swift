import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexResetCreditExpiryNotifierTests {
    @Test
    func `posts one bounded summary without persisting or logging raw credit IDs`() throws {
        let suite = "CodexResetCreditExpiryNotifierTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
    func `switching account inventories does not repeat either notification`() throws {
        let suite = "CodexResetCreditExpiryNotifierAccountTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
    func `no-expiry inventory does not trigger an expiry notification`() throws {
        let suite = "CodexResetCreditExpiryNotifierNoExpiryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
