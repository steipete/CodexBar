import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct OpenCodeGoUsageParserTests {
    private let testNow = Date(timeIntervalSince1970: 1_741_180_800) // 2025-03-05T12:00:00Z

    // MARK: - JSON with Fractional ISO8601 resetAt Dates

    @Test
    func parseJSON_withFractionalResetAt_forAllThreeWindows() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)
        let monthlyResetAt = testNow.addingTimeInterval(2_592_000)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 25.5,
                "resetAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 50.75,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
            "monthlyUsage": [
                "usagePercent": 10.25,
                "resetAt": formatter.string(from: monthlyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 25.5)
        #expect(snapshot.weeklyUsagePercent == 50.75)
        #expect(snapshot.monthlyUsagePercent == 10.25)
        #expect(snapshot.rollingResetInSec == 3600)
        #expect(snapshot.weeklyResetInSec == 604_800)
        #expect(snapshot.monthlyResetInSec == 2_592_000)
        #expect(snapshot.updatedAt == testNow)
    }

    // MARK: - JSON with Non-Fractional ISO8601 resetAt Dates

    @Test
    func parseJSON_withNonFractionalResetAt_forAllThreeWindows() throws {
        let rollingResetAt = testNow.addingTimeInterval(1800)
        let weeklyResetAt = testNow.addingTimeInterval(432_000)
        let monthlyResetAt = testNow.addingTimeInterval(1_814_400)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 15.0,
                "resetAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 60.0,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
            "monthlyUsage": [
                "usagePercent": 30.0,
                "resetAt": formatter.string(from: monthlyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 15.0)
        #expect(snapshot.weeklyUsagePercent == 60.0)
        #expect(snapshot.monthlyUsagePercent == 30.0)
        #expect(snapshot.rollingResetInSec == 1800)
        #expect(snapshot.weeklyResetInSec == 432_000)
        #expect(snapshot.monthlyResetInSec == 1_814_400)
    }

    // MARK: - JSON with Mixed Fractional and Non-Fractional resetAt Dates

    @Test
    func parseJSON_withMixedFractionalAndNonFractionalResetAt() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)
        let monthlyResetAt = testNow.addingTimeInterval(2_592_000)

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 5.5,
                "resetAt": fractionalFormatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 40.0,
                "resetAt": plainFormatter.string(from: weeklyResetAt),
            ],
            "monthlyUsage": [
                "usagePercent": 75.5,
                "resetAt": fractionalFormatter.string(from: monthlyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 5.5)
        #expect(snapshot.weeklyUsagePercent == 40.0)
        #expect(snapshot.monthlyUsagePercent == 75.5)
        #expect(snapshot.rollingResetInSec == 3600)
        #expect(snapshot.weeklyResetInSec == 604_800)
        #expect(snapshot.monthlyResetInSec == 2_592_000)
    }

    // MARK: - JSON with resetAt but NO Monthly Window (optional)

    @Test
    func parseJSON_withResetAt_onlyRollingAndWeekly() throws {
        let rollingResetAt = testNow.addingTimeInterval(2400)
        let weeklyResetAt = testNow.addingTimeInterval(518_400)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 12.0,
                "resetAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 45.5,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 12.0)
        #expect(snapshot.weeklyUsagePercent == 45.5)
        #expect(snapshot.monthlyUsagePercent == 0)
        #expect(snapshot.rollingResetInSec == 2400)
        #expect(snapshot.weeklyResetInSec == 518_400)
        #expect(snapshot.monthlyResetInSec == 0)
    }

    // MARK: - Seroval-Style Text with resetInSec

    @Test
    func parseSerovalStyle_withResetInSec_forAllThreeWindows() throws {
        let text = "rollingUsage:{usagePercent:25,resetInSec:3600}," +
            "weeklyUsage:{usagePercent:50,resetInSec:86400}," +
            "monthlyUsage:{usagePercent:10,resetInSec:2592000}"

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 50)
        #expect(snapshot.monthlyUsagePercent == 10)
        #expect(snapshot.rollingResetInSec == 3600)
        #expect(snapshot.weeklyResetInSec == 86_400)
        #expect(snapshot.monthlyResetInSec == 2_592_000)
    }

    @Test
    func parseSerovalStyle_withFractionalUsagePercent() throws {
        let text = "rollingUsage:{usagePercent:25.5,resetInSec:3600}," +
            "weeklyUsage:{usagePercent:50.75,resetInSec:86400}," +
            "monthlyUsage:{usagePercent:10.25,resetInSec:2592000}"

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 25.5)
        #expect(snapshot.weeklyUsagePercent == 50.75)
        #expect(snapshot.monthlyUsagePercent == 10.25)
        #expect(snapshot.rollingResetInSec == 3600)
        #expect(snapshot.weeklyResetInSec == 86_400)
        #expect(snapshot.monthlyResetInSec == 2_592_000)
    }

    @Test
    func parseSerovalStyle_withoutMonthlyWindow() throws {
        let text = "rollingUsage:{usagePercent:20,resetInSec:2400}," +
            "weeklyUsage:{usagePercent:55,resetInSec:518400}"

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 20)
        #expect(snapshot.weeklyUsagePercent == 55)
        #expect(snapshot.monthlyUsagePercent == 0)
        #expect(snapshot.rollingResetInSec == 2400)
        #expect(snapshot.weeklyResetInSec == 518_400)
        #expect(snapshot.monthlyResetInSec == 0)
    }

    // MARK: - JSON with resetInSec and resetAt Mixed

    @Test
    func parseJSON_withMixedResetInSecAndResetAt() throws {
        let weeklyResetAt = testNow.addingTimeInterval(604_800)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 30.0,
                "resetInSec": 3600,
            ],
            "weeklyUsage": [
                "usagePercent": 65.0,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 30.0)
        #expect(snapshot.weeklyUsagePercent == 65.0)
        #expect(snapshot.rollingResetInSec == 3600)
        #expect(snapshot.weeklyResetInSec == 604_800)
    }

    // MARK: - Edge Cases

    @Test
    func parseJSON_withZeroUsagePercent() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 0,
                "resetAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 0,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 0)
        #expect(snapshot.weeklyUsagePercent == 0)
    }

    @Test
    func parseJSON_with100PercentUsage() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 100,
                "resetAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 100,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 100)
        #expect(snapshot.weeklyUsagePercent == 100)
    }

    @Test
    func parseJSON_withFractionalPercentLessThanOne() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 0.25,
                "resetAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 0.5,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        // Values <= 1.0 and >= 0 are scaled by 100
        #expect(snapshot.rollingUsagePercent == 25.0)
        #expect(snapshot.weeklyUsagePercent == 50.0)
    }

    @Test
    func parseJSON_withZeroResetInSec() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 50,
                "resetAt": formatter.string(from: testNow),
            ],
            "weeklyUsage": [
                "usagePercent": 50,
                "resetAt": formatter.string(from: testNow),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingResetInSec == 0)
        #expect(snapshot.weeklyResetInSec == 0)
    }

    @Test
    func parseJSON_withNegativeResetInSecTreatAZero() throws {
        let pastDate = testNow.addingTimeInterval(-3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 50,
                "resetAt": formatter.string(from: pastDate),
            ],
            "weeklyUsage": [
                "usagePercent": 50,
                "resetAt": formatter.string(from: pastDate),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        // Negative values are clamped to 0
        #expect(snapshot.rollingResetInSec == 0)
        #expect(snapshot.weeklyResetInSec == 0)
    }

    // MARK: - Usage Percent Clamping

    @Test
    func parseJSON_clamps_usagePercentAbove100() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 150,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(3600)),
            ],
            "weeklyUsage": [
                "usagePercent": 200,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(604_800)),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        // Values > 100 are clamped to 100
        #expect(snapshot.rollingUsagePercent == 100)
        #expect(snapshot.weeklyUsagePercent == 100)
    }

    @Test
    func parseJSON_clamps_usagePercentBelow0() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": -10,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(3600)),
            ],
            "weeklyUsage": [
                "usagePercent": -50,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(604_800)),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        // Values < 0 are clamped to 0
        #expect(snapshot.rollingUsagePercent == 0)
        #expect(snapshot.weeklyUsagePercent == 0)
    }

    // MARK: - JSON with Alternative Keys

    @Test
    func parseJSON_withAlternativeResetAtKeys() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Using "resetsAt" instead of "resetAt"
        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 25,
                "resetsAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 50,
                "resetsAt": formatter.string(from: weeklyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 50)
        #expect(snapshot.rollingResetInSec == 3600)
        #expect(snapshot.weeklyResetInSec == 604_800)
    }

    // MARK: - JSON with Nested "usage" Key

    @Test
    func parseJSON_withNestedUsageKey() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "usage": [
                "rollingUsage": [
                    "usagePercent": 35,
                    "resetAt": formatter.string(from: rollingResetAt),
                ],
                "weeklyUsage": [
                    "usagePercent": 70,
                    "resetAt": formatter.string(from: weeklyResetAt),
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingUsagePercent == 35)
        #expect(snapshot.weeklyUsagePercent == 70)
    }

    // MARK: - JSON with Used and Limit (Computed Percent)

    @Test
    func parseJSON_computesPercentFromUsedAndLimit() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "used": 25,
                "limit": 100,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(3600)),
            ],
            "weeklyUsage": [
                "used": 50,
                "limit": 200,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(604_800)),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        // used / limit * 100
        #expect(snapshot.rollingUsagePercent == 25.0)
        #expect(snapshot.weeklyUsagePercent == 25.0)
    }

    // MARK: - Error Cases

    @Test
    func parseJSON_throwsWhenMissingRolling() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "weeklyUsage": [
                "usagePercent": 50,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(604_800)),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)
        }
    }

    @Test
    func parseJSON_throwsWhenMissingWeekly() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 25,
                "resetAt": formatter.string(from: testNow.addingTimeInterval(3600)),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)
        }
    }

    @Test
    func parseSeroval_throwsWhenMissingRolling() {
        let text = "weeklyUsage:{usagePercent:50,resetInSec:86400}"

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)
        }
    }

    @Test
    func parseSeroval_throwsWhenMissingWeekly() {
        let text = "rollingUsage:{usagePercent:25,resetInSec:3600}"

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)
        }
    }

    @Test
    func parseInvalidJSON_throwsError() {
        let text = "{not valid json"

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)
        }
    }

    @Test
    func parseEmptyString_throwsError() {
        let text = ""

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)
        }
    }

    // MARK: - Decimal and Scientific Notation

    @Test
    func parseJSON_withScientificNotationPercent() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 1e-2,  // 0.01
                "resetAt": formatter.string(from: testNow.addingTimeInterval(3600)),
            ],
            "weeklyUsage": [
                "usagePercent": 5e1,  // 50
                "resetAt": formatter.string(from: testNow.addingTimeInterval(604_800)),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        // 1e-2 = 0.01, which is < 1 and >= 0, so scaled by 100 -> 1.0
        #expect(snapshot.rollingUsagePercent == 1.0)
        // 5e1 = 50.0, which is > 1, so not scaled
        #expect(snapshot.weeklyUsagePercent == 50.0)
    }

    // MARK: - Updated At Timestamp

    @Test
    func parseSnapshot_preservesUpdatedAtTimestamp() throws {
        let rollingResetAt = testNow.addingTimeInterval(3600)
        let weeklyResetAt = testNow.addingTimeInterval(604_800)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 25,
                "resetAt": formatter.string(from: rollingResetAt),
            ],
            "weeklyUsage": [
                "usagePercent": 50,
                "resetAt": formatter.string(from: weeklyResetAt),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.updatedAt == testNow)
    }

    // MARK: - Large Reset In Seconds Values

    @Test
    func parseJSON_withLargeResetInSecValues() throws {
        let largeRollingReset = testNow.addingTimeInterval(86_400)  // 1 day
        let largeWeeklyReset = testNow.addingTimeInterval(2_592_000)  // 30 days

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 10,
                "resetAt": formatter.string(from: largeRollingReset),
            ],
            "weeklyUsage": [
                "usagePercent": 20,
                "resetAt": formatter.string(from: largeWeeklyReset),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: testNow)

        #expect(snapshot.rollingResetInSec == 86_400)
        #expect(snapshot.weeklyResetInSec == 2_592_000)
    }
}
