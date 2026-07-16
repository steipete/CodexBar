import CodexBarCore
import Foundation
import XCTest

final class ResetTimeBackfillTests: XCTestCase {
    func test_backfillsMissingResetMetadataFromCachedWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let cached = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: reset,
            resetDescription: "Resets in 1h",
            nextRegenPercent: 9)
        let fresh = RateWindow(
            usedPercent: 62,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil,
            nextRegenPercent: 4)

        let result = fresh.backfillingResetTime(from: cached, now: now)

        XCTAssertEqual(result.usedPercent, 62)
        XCTAssertEqual(result.windowMinutes, 300)
        XCTAssertEqual(result.resetsAt, reset)
        XCTAssertEqual(result.resetDescription, "Resets in 1h")
        XCTAssertEqual(result.nextRegenPercent, 4)
    }

    func test_backfillsZeroWindowDurationFromCachedWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let cached = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: reset,
            resetDescription: nil)
        let fresh = RateWindow(usedPercent: 62, windowMinutes: 0, resetsAt: nil, resetDescription: nil)

        let result = fresh.backfillingResetTime(from: cached, now: now)

        XCTAssertEqual(result.windowMinutes, 300)
        XCTAssertEqual(result.resetsAt, reset)
    }

    func test_skipsExpiredCachedReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(-60),
            resetDescription: "Expired")
        let fresh = RateWindow(usedPercent: 62, windowMinutes: nil, resetsAt: nil, resetDescription: nil)

        let result = fresh.backfillingResetTime(from: cached, now: now)

        XCTAssertNil(result.resetsAt)
        XCTAssertNil(result.windowMinutes)
        XCTAssertNil(result.resetDescription)
    }

    func test_snapshotBackfillPreservesCurrentSnapshotFields() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "peter@example.com",
            accountOrganization: "Org",
            loginMethod: "OAuth")
        let cached = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: reset, resetDescription: "Soon"),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-300),
            identity: identity)
        let extra = NamedRateWindow(
            id: "overflow",
            title: "Overflow",
            window: RateWindow(
                usedPercent: 12,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil,
                nextRegenPercent: 2))
        let fresh = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 66,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil,
                nextRegenPercent: 7),
            secondary: nil,
            extraRateWindows: [extra],
            cursorRequests: CursorRequestUsage(used: 10, limit: 50),
            subscriptionExpiresAt: reset.addingTimeInterval(86400),
            subscriptionRenewsAt: reset.addingTimeInterval(43200),
            updatedAt: now,
            identity: identity)

        let result = fresh.backfillingResetTimes(from: cached, now: now)

        XCTAssertEqual(result.primary?.resetsAt, reset)
        XCTAssertEqual(result.primary?.usedPercent, 66)
        XCTAssertEqual(result.primary?.nextRegenPercent, 7)
        XCTAssertEqual(result.extraRateWindows?.first?.id, "overflow")
        XCTAssertEqual(result.extraRateWindows?.first?.window.nextRegenPercent, 2)
        XCTAssertEqual(result.cursorRequests?.used, 10)
        XCTAssertEqual(result.subscriptionExpiresAt, reset.addingTimeInterval(86400))
        XCTAssertEqual(result.subscriptionRenewsAt, reset.addingTimeInterval(43200))
        XCTAssertEqual(result.identity?.accountEmail, "peter@example.com")
    }

    func test_snapshotBackfillSkipsDifferentAccounts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "Soon"),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-300),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "old@example.com",
                accountOrganization: nil,
                loginMethod: nil))
        let fresh = UsageSnapshot(
            primary: RateWindow(usedPercent: 66, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "new@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        let result = fresh.backfillingResetTimes(from: cached, now: now)

        XCTAssertNil(result.primary?.resetsAt)
    }

    func test_snapshotBackfillSkipsSameEmailWithDifferentStableAccountIDs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "Soon"),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-300),
            identity: ProviderIdentitySnapshot(
                providerID: .cursor,
                accountEmail: "shared@example.com",
                accountOrganization: nil,
                loginMethod: nil,
                accountID: "account-a"))
        let fresh = UsageSnapshot(
            primary: RateWindow(usedPercent: 66, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .cursor,
                accountEmail: "shared@example.com",
                accountOrganization: nil,
                loginMethod: nil,
                accountID: "account-b"))

        let result = fresh.backfillingResetTimes(from: cached, now: now)

        XCTAssertNil(result.primary?.resetsAt)
    }

    func test_snapshotBackfillKeepsOtherProviderResetWhenDescriptionChanges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: nil)
        let cached = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 300,
                resetsAt: reset,
                resetDescription: "40 / 100 used"),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-300),
            identity: identity)
        let fresh = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: "50 / 100 used"),
            secondary: nil,
            updatedAt: now,
            identity: identity)

        let result = fresh.backfillingResetTimes(from: cached, now: now)

        XCTAssertEqual(result.primary?.resetsAt, reset)
        XCTAssertEqual(result.primary?.resetDescription, "50 / 100 used")
    }
}
