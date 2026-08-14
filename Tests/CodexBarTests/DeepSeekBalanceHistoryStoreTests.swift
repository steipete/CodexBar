@testable import CodexBarCore
import Foundation
import XCTest

final class DeepSeekBalanceHistoryStoreTests: XCTestCase {
    private var directoryURL: URL!

    override func setUp() {
        super.setUp()
        self.directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekBalanceHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.directoryURL)
        super.tearDown()
    }

    private func makeStore() -> DeepSeekBalanceHistoryStore {
        DeepSeekBalanceHistoryStore(
            fileURL: self.directoryURL.appendingPathComponent("history.json"),
            calendar: Self.fixedCalendar())
    }

    private static func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        components.hour = hour
        return Self.fixedCalendar().date(from: components)!
    }

    func testNoHistoryReturnsUnavailable() {
        let store = self.makeStore()
        let summary = store.consumptionSummary(for: "default", currentBalance: 100, currency: "CNY", now: self.date(15))
        XCTAssertNil(summary.totalSpent)
        XCTAssertNil(summary.todaySpent)
    }

    func testRecordsAndDerivesSpend() {
        let store = self.makeStore()
        // Aug 13: 100
        store.record(balance: 100, currency: "CNY", accountKey: "default", at: self.date(13, hour: 9))
        // Aug 14: 95
        store.record(balance: 95, currency: "CNY", accountKey: "default", at: self.date(14, hour: 9))
        // Aug 15 (today) morning: 90
        store.record(balance: 90, currency: "CNY", accountKey: "default", at: self.date(15, hour: 9))

        let summary = store.consumptionSummary(
            for: "default",
            currentBalance: 88,
            currency: "CNY",
            now: self.date(15, hour: 14))
        XCTAssertEqual(summary.totalSpent ?? -1, 12, accuracy: 0.0001) // 100 - 88
        XCTAssertEqual(summary.todaySpent ?? -1, 2, accuracy: 0.0001) // 90 - 88
        XCTAssertEqual(summary.todayStartBalance ?? -1, 90, accuracy: 0.0001)
    }

    func testRechargeResetsBaseline() {
        let store = self.makeStore()
        store.record(balance: 100, currency: "CNY", accountKey: "default", at: self.date(13, hour: 9))
        store.record(balance: 80, currency: "CNY", accountKey: "default", at: self.date(14, hour: 9))
        // Recharge on Aug 15: 200 (top-up)
        store.record(balance: 200, currency: "CNY", accountKey: "default", at: self.date(15, hour: 9))
        // Spent some after top-up
        let summary = store.consumptionSummary(
            for: "default",
            currentBalance: 195,
            currency: "CNY",
            now: self.date(15, hour: 14))
        // Lifetime spend is measured from the newest baseline (200), not the original 100.
        XCTAssertEqual(summary.totalSpent ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.todaySpent ?? -1, 5, accuracy: 0.0001)
    }

    func testRechargeTodayStillReportsPostRechargeSpend() {
        let store = self.makeStore()
        store.record(balance: 100, currency: "CNY", accountKey: "default", at: self.date(14, hour: 9))
        // Top-up this morning pushed the balance to 150; spending since then is
        // attributable to the post-recharge segment.
        store.record(balance: 150, currency: "CNY", accountKey: "default", at: self.date(15, hour: 9))
        let summary = store.consumptionSummary(
            for: "default",
            currentBalance: 148,
            currency: "CNY",
            now: self.date(15, hour: 14))
        XCTAssertEqual(summary.todaySpent ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(summary.totalSpent ?? -1, 2, accuracy: 0.0001)
    }

    func testRechargeDayWithoutRefreshYieldsNoTodaySpend() {
        let store = self.makeStore()
        store.record(balance: 100, currency: "CNY", accountKey: "default", at: self.date(14, hour: 9))
        // No sample recorded today yet; the current balance is already above
        // yesterday's closing balance because of a top-up, so no spend is shown.
        let summary = store.consumptionSummary(
            for: "default",
            currentBalance: 150,
            currency: "CNY",
            now: self.date(15, hour: 14))
        XCTAssertEqual(summary.todaySpent ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(summary.totalSpent ?? -1, 0, accuracy: 0.0001)
    }

    func testMidDayRechargeAttributesPostRechargeSpend() {
        let store = self.makeStore()
        // Morning: 90. Mid-day top-up: 200. Now: 195.
        store.record(balance: 90, currency: "CNY", accountKey: "default", at: self.date(15, hour: 9))
        store.record(balance: 200, currency: "CNY", accountKey: "default", at: self.date(15, hour: 12))
        let summary = store.consumptionSummary(
            for: "default",
            currentBalance: 195,
            currency: "CNY",
            now: self.date(15, hour: 14))
        // Today's spend is measured from the post-recharge balance (200 → 195).
        XCTAssertEqual(summary.todaySpent ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.totalSpent ?? -1, 5, accuracy: 0.0001)
    }

    func testMultipleAccountKeysAreIsolated() {
        let store = self.makeStore()
        store.record(balance: 100, currency: "CNY", accountKey: "key-a", at: self.date(14, hour: 9))
        store.record(balance: 500, currency: "CNY", accountKey: "key-b", at: self.date(14, hour: 9))
        let summaryA = store.consumptionSummary(
            for: "key-a",
            currentBalance: 90,
            currency: "CNY",
            now: self.date(15, hour: 14))
        let summaryB = store.consumptionSummary(
            for: "key-b",
            currentBalance: 480,
            currency: "CNY",
            now: self.date(15, hour: 14))
        XCTAssertEqual(summaryA.totalSpent ?? -1, 10, accuracy: 0.0001)
        XCTAssertEqual(summaryB.totalSpent ?? -1, 20, accuracy: 0.0001)
    }

    func testPersistenceRoundTrip() {
        let fileURL = self.directoryURL.appendingPathComponent("history.json")
        let store = DeepSeekBalanceHistoryStore(
            fileURL: fileURL,
            calendar: Self.fixedCalendar())
        store.record(balance: 100, currency: "CNY", accountKey: "default", at: self.date(14, hour: 9))

        // A fresh store instance reading the same file must see the record.
        let reloaded = DeepSeekBalanceHistoryStore(
            fileURL: fileURL,
            calendar: Self.fixedCalendar())
        let summary = reloaded.consumptionSummary(
            for: "default",
            currentBalance: 95,
            currency: "CNY",
            now: self.date(15, hour: 14))
        XCTAssertEqual(summary.totalSpent ?? -1, 5, accuracy: 0.0001)
    }

    func testPersistedHistoryContainsNoAPIKeyFragments() throws {
        let fileURL = self.directoryURL.appendingPathComponent("history.json")
        let store = DeepSeekBalanceHistoryStore(
            fileURL: fileURL,
            calendar: Self.fixedCalendar())

        // Test-only credential-shaped string (not a real secret; deliberately
        // avoids a credential-shaped prefix so secret scanners stay quiet).
        let apiKey = "test-credential-9f8e7d6c5b4a39281706f5e4d3c2b1a0"
        let accountKey = DeepSeekProviderDescriptor.balanceAccountKeyForTesting(apiKey: apiKey)
        store.record(balance: 100, currency: "CNY", accountKey: accountKey, at: self.date(14, hour: 9))
        store.record(balance: 95, currency: "CNY", accountKey: accountKey, at: self.date(15, hour: 9))

        let data = try Data(contentsOf: fileURL)
        let json = String(data: data, encoding: .utf8) ?? ""

        // No raw key fragment may appear in the persisted payload.
        XCTAssertFalse(json.contains(apiKey))
        XCTAssertFalse(json.contains("9f8e7d6c"))
        XCTAssertFalse(json.contains("c2b1a0"))
        XCTAssertFalse(json.contains("9f8e7d6c"))
        // Account key must be a namespaced digest.
        XCTAssertTrue(accountKey.hasPrefix("v1:"))
        XCTAssertNotEqual(accountKey, apiKey)
        XCTAssertGreaterThan(accountKey.count, 40)
    }

    func testDigestAccountKeyIsStableAndIsolated() {
        let keyA = DeepSeekProviderDescriptor.balanceAccountKeyForTesting(apiKey: "test-credential-aaaaaaaaaaaaaaaa")
        let keyA2 = DeepSeekProviderDescriptor.balanceAccountKeyForTesting(apiKey: "test-credential-aaaaaaaaaaaaaaaa")
        let keyB = DeepSeekProviderDescriptor.balanceAccountKeyForTesting(apiKey: "test-credential-bbbbbbbbbbbbbbbb")

        XCTAssertEqual(keyA, keyA2, "same key must map to same digest")
        XCTAssertNotEqual(keyA, keyB, "different keys must map to different digests")
        XCTAssertEqual(
            DeepSeekProviderDescriptor.balanceAccountKeyForTesting(apiKey: nil),
            "default",
            "nil key falls back to default")
    }

    func testIgnoredInvalidBalance() {
        let store = self.makeStore()
        store.record(balance: -5, currency: "CNY", accountKey: "default", at: self.date(14, hour: 9))
        store.record(balance: .infinity, currency: "CNY", accountKey: "default", at: self.date(14, hour: 10))
        let summary = store.consumptionSummary(
            for: "default",
            currentBalance: 95,
            currency: "CNY",
            now: self.date(15, hour: 14))
        XCTAssertNil(summary.totalSpent)
    }
}
