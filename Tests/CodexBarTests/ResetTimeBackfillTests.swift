import CodexBarCore
import Foundation
import XCTest

final class ResetTimeBackfillTests: XCTestCase {
    func test_backfillsNilResetFromCache() {
        let future = Date().addingTimeInterval(3600)
        let cached = RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: future, resetDescription: "in 1h")
        let fresh = RateWindow(usedPercent: 60, windowMinutes: 300, resetsAt: nil, resetDescription: nil)

        let result = fresh.backfillingResetTime(from: cached)

        XCTAssertEqual(result.usedPercent, 60)
        XCTAssertEqual(result.resetsAt, future)
        XCTAssertEqual(result.resetDescription, "in 1h")
    }

    func test_doesNotBackfillWhenFreshHasReset() {
        let future1 = Date().addingTimeInterval(3600)
        let future2 = Date().addingTimeInterval(7200)
        let cached = RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: future1, resetDescription: nil)
        let fresh = RateWindow(usedPercent: 60, windowMinutes: 300, resetsAt: future2, resetDescription: nil)

        let result = fresh.backfillingResetTime(from: cached)

        XCTAssertEqual(result.resetsAt, future2)
    }

    func test_doesNotBackfillExpiredCachedReset() {
        let past = Date().addingTimeInterval(-60)
        let cached = RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: past, resetDescription: nil)
        let fresh = RateWindow(usedPercent: 60, windowMinutes: 300, resetsAt: nil, resetDescription: nil)

        let result = fresh.backfillingResetTime(from: cached)

        XCTAssertNil(result.resetsAt)
    }

    func test_backfillsWindowMinutesFromCache() {
        let future = Date().addingTimeInterval(3600)
        let cached = RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: future, resetDescription: nil)
        let fresh = RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil)

        let result = fresh.backfillingResetTime(from: cached)

        XCTAssertEqual(result.windowMinutes, 300)
    }

    func test_snapshotBackfillsPrimaryAndSecondary() {
        let future = Date().addingTimeInterval(3600)
        let cachedPrimary = RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: future, resetDescription: nil)
        let cachedSecondary = RateWindow(
            usedPercent: 30, windowMinutes: 10080, resetsAt: future, resetDescription: nil)
        let cached = UsageSnapshot(
            primary: cachedPrimary, secondary: cachedSecondary, updatedAt: Date().addingTimeInterval(-300))

        let freshPrimary = RateWindow(usedPercent: 55, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let freshSecondary = RateWindow(usedPercent: 35, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let fresh = UsageSnapshot(primary: freshPrimary, secondary: freshSecondary, updatedAt: Date())

        let result = fresh.backfillingResetTimes(from: cached)

        XCTAssertEqual(result.primary?.resetsAt, future)
        XCTAssertEqual(result.secondary?.resetsAt, future)
        XCTAssertEqual(result.primary?.usedPercent, 55)
        XCTAssertEqual(result.secondary?.usedPercent, 35)
    }

    func test_snapshotSkipsBackfillOnAccountChange() {
        let future = Date().addingTimeInterval(3600)
        let oldIdentity = ProviderIdentitySnapshot(
            providerID: .claude, accountEmail: "old@example.com", accountOrganization: nil, loginMethod: nil)
        let newIdentity = ProviderIdentitySnapshot(
            providerID: .claude, accountEmail: "new@example.com", accountOrganization: nil, loginMethod: nil)

        let cached = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: future, resetDescription: nil),
            secondary: nil,
            updatedAt: Date().addingTimeInterval(-300),
            identity: oldIdentity)

        let fresh = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: newIdentity)

        let result = fresh.backfillingResetTimes(from: cached)

        XCTAssertNil(result.primary?.resetsAt, "Should not backfill across different accounts")
    }

    func test_snapshotBackfillsWhenIdentityMatches() {
        let future = Date().addingTimeInterval(3600)
        let identity = ProviderIdentitySnapshot(
            providerID: .claude, accountEmail: "same@example.com", accountOrganization: nil, loginMethod: nil)

        let cached = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: future, resetDescription: nil),
            secondary: nil,
            updatedAt: Date().addingTimeInterval(-300),
            identity: identity)

        let fresh = UsageSnapshot(
            primary: RateWindow(usedPercent: 60, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: identity)

        let result = fresh.backfillingResetTimes(from: cached)

        XCTAssertEqual(result.primary?.resetsAt, future)
    }

    func test_snapshotNoOpWhenNoCachedData() {
        let fresh = UsageSnapshot(
            primary: RateWindow(usedPercent: 55, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        let result = fresh.backfillingResetTimes(from: nil)

        XCTAssertNil(result.primary?.resetsAt)
    }
}
