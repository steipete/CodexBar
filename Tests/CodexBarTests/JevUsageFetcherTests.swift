import XCTest
@testable import CodexBarCore

final class JevUsageFetcherTests: XCTestCase {
    func testSummarizesDailyBucketsAndUsesFirstAccountEmail() {
        let response = JevUsageResponse(buckets: [
            JevUsageBucket(day: "2026-09-17", requests: 4, inputTokens: 100, outputTokens: 25, userEmail: ""),
            JevUsageBucket(
                day: "2026-09-18",
                requests: 6,
                inputTokens: 250,
                outputTokens: 50,
                userEmail: "user@example.com"),
        ])

        let summary = JevUsageFetcher.summarize(response, now: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(summary.requests, 10)
        XCTAssertEqual(summary.inputTokens, 350)
        XCTAssertEqual(summary.outputTokens, 75)
        XCTAssertEqual(summary.accountEmail, "user@example.com")
        XCTAssertEqual(summary.toUsageSnapshot().details.first?.rows.map(\.value), ["10", "350", "75", "425"])
    }
}
