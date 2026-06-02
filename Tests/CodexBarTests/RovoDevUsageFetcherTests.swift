import Foundation
import XCTest
@testable import CodexBarCore

final class RovoDevUsageFetcherTests: XCTestCase {
    // MARK: - Settings reader tests

    func test_apiToken_returnsNilWhenMissing() {
        XCTAssertNil(RovoDevSettingsReader.apiToken(environment: [:]))
    }

    func test_apiToken_returnsValue() {
        let env = [RovoDevSettingsReader.apiTokenEnvironmentKey: "my-token"]
        XCTAssertEqual(RovoDevSettingsReader.apiToken(environment: env), "my-token")
    }

    func test_email_returnsNilWhenMissing() {
        XCTAssertNil(RovoDevSettingsReader.email(environment: [:]))
    }

    func test_email_returnsValue() {
        let env = [RovoDevSettingsReader.emailEnvironmentKey: "user@example.com"]
        XCTAssertEqual(RovoDevSettingsReader.email(environment: env), "user@example.com")
    }

    func test_apiURL_defaultsToAtlassian() {
        let url = RovoDevSettingsReader.apiURL(environment: [:])
        XCTAssertEqual(url.absoluteString, "https://api.atlassian.com")
    }

    func test_apiURL_overrideViaEnv() {
        let env = [RovoDevSettingsReader.apiURLEnvironmentKey: "https://my-proxy.example.com"]
        let url = RovoDevSettingsReader.apiURL(environment: env)
        XCTAssertEqual(url.absoluteString, "https://my-proxy.example.com")
    }

    func test_cleaned_stripsWhitespace() {
        XCTAssertEqual(RovoDevSettingsReader.cleaned("  hello  "), "hello")
    }

    func test_cleaned_stripsQuotes() {
        XCTAssertEqual(RovoDevSettingsReader.cleaned("\"hello\""), "hello")
        XCTAssertEqual(RovoDevSettingsReader.cleaned("'hello'"), "hello")
    }

    func test_cleaned_returnsNilForEmpty() {
        XCTAssertNil(RovoDevSettingsReader.cleaned(""))
        XCTAssertNil(RovoDevSettingsReader.cleaned("   "))
        XCTAssertNil(RovoDevSettingsReader.cleaned(nil))
    }

    // MARK: - Parser tests

    func test_parseSnapshot_okStatus_monthly() throws {
        let json = """
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 847,
                "monthlyRemaining": 1153
            }
        }
        """.data(using: .utf8)!

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.status, "OK")
        XCTAssertEqual(snapshot.creditsUsed, 847)
        XCTAssertEqual(snapshot.creditsTotal, 2000)
        XCTAssertEqual(snapshot.balance.monthlyRemaining, 1153)
    }

    func test_parseSnapshot_fallsBackToDaily() throws {
        let json = """
        {
            "status": "OK",
            "balance": {
                "dailyTotal": 500,
                "dailyUsed": 100,
                "dailyRemaining": 400
            }
        }
        """.data(using: .utf8)!

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.creditsUsed, 100)
        XCTAssertEqual(snapshot.creditsTotal, 500)
    }

    func test_parseSnapshot_usedPercent() throws {
        let json = """
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 1000
            }
        }
        """.data(using: .utf8)!

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.usedPercent, 50.0, accuracy: 0.001)
    }

    func test_parseSnapshot_rateLimitedStatus() throws {
        let json = """
        {
            "status": "RATE_LIMITED",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 2000
            },
            "message": "Monthly credit limit reached"
        }
        """.data(using: .utf8)!

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.status, "RATE_LIMITED")
        XCTAssertEqual(snapshot.message, "Monthly credit limit reached")
        XCTAssertEqual(snapshot.usedPercent, 100.0, accuracy: 0.001)
    }

    func test_parseSnapshot_emptyBalance() throws {
        let json = """
        {
            "status": "UNKNOWN",
            "balance": {}
        }
        """.data(using: .utf8)!

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertNil(snapshot.creditsUsed)
        XCTAssertNil(snapshot.creditsTotal)
        XCTAssertEqual(snapshot.usedPercent, 0.0, accuracy: 0.001)
    }

    func test_parseSnapshot_invalidJSON_throwsParseFailed() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(
            try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date()))
        { error in
            guard case RovoDevUsageError.parseFailed = error else {
                return XCTFail("Expected parseFailed, got \(error)")
            }
        }
    }

    func test_creditsCheckURL_isCorrect() throws {
        let base = try XCTUnwrap(URL(string: "https://api.atlassian.com"))
        let url = RovoDevUsageFetcher._creditsCheckURLForTesting(baseURL: base)
        XCTAssertEqual(url.absoluteString, "https://api.atlassian.com/rovodev/v3/credits/check")
    }

    func test_usageSnapshot_toUsageSnapshot_returnsValidSnapshot() throws {
        let json = """
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 400
            }
        }
        """.data(using: .utf8)!

        let rovoDev = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        let usage = rovoDev.toUsageSnapshot()
        XCTAssertEqual(usage.primary.usedPercent, 20.0, accuracy: 0.001)
        XCTAssertEqual(usage.identity?.providerID, .rovodev)
    }

    // MARK: - Error equality

    func test_errorEquality() {
        XCTAssertEqual(RovoDevUsageError.missingCredentials, RovoDevUsageError.missingCredentials)
        XCTAssertNotEqual(RovoDevUsageError.missingCredentials, RovoDevUsageError.apiError(401))
    }
}
