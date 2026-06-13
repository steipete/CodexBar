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

    func test_apiURL_acceptsBareHTTPSHost() throws {
        let env = [RovoDevSettingsReader.apiURLEnvironmentKey: "my-proxy.example.com"]
        try RovoDevSettingsReader.validateEndpointOverrides(environment: env)
        XCTAssertEqual(RovoDevSettingsReader.apiURL(environment: env).absoluteString, "https://my-proxy.example.com")
    }

    func test_apiURL_rejectsInsecureOrUserInfoOverrides() {
        let invalidURLs = [
            "http://attacker.example.com",
            "https://user:pass@attacker.example.com",
            "https://proxy.example.com%2f.attacker.example.com",
        ]

        for invalidURL in invalidURLs {
            let env = [RovoDevSettingsReader.apiURLEnvironmentKey: invalidURL]
            XCTAssertThrowsError(try RovoDevSettingsReader.validateEndpointOverrides(environment: env)) { error in
                XCTAssertEqual(
                    error as? RovoDevSettingsError,
                    .invalidEndpointOverride(RovoDevSettingsReader.apiURLEnvironmentKey))
            }
            XCTAssertEqual(RovoDevSettingsReader.apiURL(environment: env).host, "api.atlassian.com")
        }
    }

    func test_fetchUsage_rejectsInsecureOverrideBeforeRequest() async {
        do {
            _ = try await RovoDevUsageFetcher.fetchUsage(
                email: "user@example.com",
                apiToken: "secret",
                environment: [RovoDevSettingsReader.apiURLEnvironmentKey: "http://attacker.example.com"])
            XCTFail("Expected invalid endpoint override")
        } catch {
            XCTAssertEqual(
                error as? RovoDevSettingsError,
                .invalidEndpointOverride(RovoDevSettingsReader.apiURLEnvironmentKey))
        }
    }

    func test_fetchUsage_acceptsRecognizedBlockedResponse() async throws {
        let transport = Self.makeTransport(
            statusCode: 403,
            body: """
            {
                "status": "USER_BLOCKED",
                "message": "Rovo Dev access is blocked"
            }
            """)

        let snapshot = try await RovoDevUsageFetcher.fetchUsage(
            email: " user@example.com ",
            apiToken: "secret",
            environment: [:],
            transport: transport)

        XCTAssertEqual(snapshot.status, "USER_BLOCKED")
        XCTAssertEqual(snapshot.message, "Rovo Dev access is blocked")
        XCTAssertEqual(snapshot.accountEmail, "user@example.com")
    }

    func test_fetchUsage_rejectsGenericForbiddenResponse() async {
        let transport = Self.makeTransport(
            statusCode: 403,
            body: #"{"error":"Forbidden","message":"Access denied"}"#)

        do {
            _ = try await RovoDevUsageFetcher.fetchUsage(
                email: "user@example.com",
                apiToken: "secret",
                environment: [:],
                transport: transport)
            XCTFail("Expected generic forbidden response to fail")
        } catch {
            XCTAssertEqual(error as? RovoDevUsageError, .apiError(403))
        }
    }

    func test_fetchUsage_rejectsGenericSuccessfulResponse() async {
        let transport = Self.makeTransport(
            statusCode: 200,
            body: #"{"message":"Request completed"}"#)

        do {
            _ = try await RovoDevUsageFetcher.fetchUsage(
                email: "user@example.com",
                apiToken: "secret",
                environment: [:],
                transport: transport)
            XCTFail("Expected unrecognized successful response to fail")
        } catch {
            guard case let RovoDevUsageError.parseFailed(message) = error else {
                return XCTFail("Expected parseFailed, got \(error)")
            }
            XCTAssertEqual(message, "Unrecognized response payload")
        }
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
        let json = Data("""
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 847,
                "monthlyRemaining": 1153
            }
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.status, "OK")
        XCTAssertEqual(snapshot.creditsUsed, 847)
        XCTAssertEqual(snapshot.creditsTotal, 2000)
        XCTAssertEqual(snapshot.balance.monthlyRemaining, 1153)
    }

    func test_parseSnapshot_fallsBackToDaily() throws {
        let json = Data("""
        {
            "status": "OK",
            "balance": {
                "dailyTotal": 500,
                "dailyUsed": 100,
                "dailyRemaining": 400
            }
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.creditsUsed, 100)
        XCTAssertEqual(snapshot.creditsTotal, 500)
    }

    func test_parseSnapshot_derivesMonthlyUsedFromRemaining() throws {
        let json = Data("""
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyRemaining": 1153
            }
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.creditsUsed, 847)
        XCTAssertEqual(snapshot.creditsTotal, 2000)
        XCTAssertEqual(snapshot.usedPercent, 42.35, accuracy: 0.001)
    }

    func test_parseSnapshot_derivesDailyUsedFromRemaining() throws {
        let json = Data("""
        {
            "status": "OK",
            "balance": {
                "dailyTotal": 500,
                "dailyRemaining": 400
            }
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.creditsUsed, 100)
        XCTAssertEqual(snapshot.creditsTotal, 500)
        XCTAssertEqual(snapshot.usedPercent, 20.0, accuracy: 0.001)
    }

    func test_parseSnapshot_keepsDailyUsagePairedWithDailyTotal() throws {
        let json = Data("""
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "dailyTotal": 500,
                "dailyUsed": 100
            }
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.creditsUsed, 100)
        XCTAssertEqual(snapshot.creditsTotal, 500)
        XCTAssertEqual(snapshot.usedPercent, 20.0, accuracy: 0.001)
    }

    func test_parseSnapshot_usedPercent() throws {
        let json = Data("""
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 1000
            }
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.usedPercent, 50.0, accuracy: 0.001)
    }

    func test_parseSnapshot_rateLimitedStatus() throws {
        let json = Data("""
        {
            "status": "RATE_LIMITED",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 2000
            },
            "message": "Monthly credit limit reached"
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertEqual(snapshot.status, "RATE_LIMITED")
        XCTAssertEqual(snapshot.message, "Monthly credit limit reached")
        XCTAssertEqual(snapshot.usedPercent, 100.0, accuracy: 0.001)
    }

    func test_parseSnapshot_emptyBalance() throws {
        let json = Data("""
        {
            "status": "UNKNOWN",
            "balance": {}
        }
        """.utf8)

        let snapshot = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        XCTAssertNil(snapshot.creditsUsed)
        XCTAssertNil(snapshot.creditsTotal)
        XCTAssertEqual(snapshot.usedPercent, 0.0, accuracy: 0.001)
    }

    func test_parseSnapshot_invalidJSON_throwsParseFailed() {
        let json = Data("not json".utf8)
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
        let json = Data("""
        {
            "status": "OK",
            "balance": {
                "monthlyTotal": 2000,
                "monthlyUsed": 400
            }
        }
        """.utf8)

        let rovoDev = try RovoDevUsageFetcher._parseSnapshotForTesting(json, updatedAt: Date())
        let usage = rovoDev.toUsageSnapshot()
        XCTAssertEqual(try XCTUnwrap(usage.primary).usedPercent, 20.0, accuracy: 0.001)
        XCTAssertEqual(usage.identity?.providerID, .rovodev)
    }

    func test_usageSnapshot_preservesConfiguredAccountEmail() {
        let snapshot = RovoDevUsageSnapshot(
            status: "OK",
            balance: RovoDevBalance(
                dailyTotal: nil,
                dailyRemaining: nil,
                dailyUsed: nil,
                monthlyTotal: 2000,
                monthlyRemaining: 1600,
                monthlyUsed: 400),
            message: nil,
            accountEmail: "user@example.com",
            updatedAt: Date())

        XCTAssertEqual(snapshot.toUsageSnapshot().identity?.accountEmail, "user@example.com")
    }

    func test_costUsageScanner_returnsEmptyReport() {
        let now = Date()
        let report = CostUsageScanner.loadDailyReport(
            provider: .rovodev,
            since: now.addingTimeInterval(-3600),
            until: now,
            now: now)

        XCTAssertTrue(report.data.isEmpty)
        XCTAssertNil(report.summary)
    }

    // MARK: - Error equality

    func test_errorEquality() {
        XCTAssertEqual(RovoDevUsageError.missingCredentials, RovoDevUsageError.missingCredentials)
        XCTAssertNotEqual(RovoDevUsageError.missingCredentials, RovoDevUsageError.apiError(401))
    }

    private static func makeTransport(
        statusCode: Int,
        body: String) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["Content-Type": "application/json"])
            else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
    }
}
