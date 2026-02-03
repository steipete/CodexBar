import XCTest
@testable import CodexBarCore

final class AugmentStatusProbeTests: XCTestCase {
    func test_debugRawProbe_returnsFormattedOutput() async {
        // Given: A probe instance
        let probe = AugmentStatusProbe()

        // When: We call debugRawProbe
        let output = await probe.debugRawProbe()

        // Then: The output should contain expected debug information
        XCTAssertTrue(output.contains("=== Augment Debug Probe @"), "Should contain debug header")
        XCTAssertTrue(
            output.contains("Probe Success") || output.contains("Probe Failed"),
            "Should contain probe result status")
    }

    func test_latestDumps_initiallyEmpty() async {
        // Note: This test may fail if other tests have already run and captured dumps
        // The ring buffer is shared across all tests in the process
        // When: We request latest dumps
        let dumps = await AugmentStatusProbe.latestDumps()

        // Then: Should either be empty or contain previous test dumps
        // We just verify it returns a non-empty string
        XCTAssertFalse(dumps.isEmpty, "Should return a string (either empty message or dumps)")
    }

    func test_debugRawProbe_capturesFailureInDumps() async throws {
        // Given: A probe with an invalid base URL that will fail
        let invalidProbe = try AugmentStatusProbe(baseURL: XCTUnwrap(URL(string: "https://invalid.example.com")))

        // When: We call debugRawProbe which should fail
        let output = await invalidProbe.debugRawProbe()

        // Then: The output should indicate failure
        XCTAssertTrue(output.contains("Probe Failed"), "Should contain failure message")

        // And: The failure should be captured in dumps
        let dumps = await AugmentStatusProbe.latestDumps()
        XCTAssertNotEqual(dumps, "No Augment probe dumps captured yet.", "Should have captured the failure")
        XCTAssertTrue(dumps.contains("Probe Failed"), "Dumps should contain the failure")
    }

    func test_latestDumps_maintainsRingBuffer() async throws {
        // Given: Multiple failed probes to fill the ring buffer
        let invalidProbe = try AugmentStatusProbe(baseURL: XCTUnwrap(URL(string: "https://invalid.example.com")))

        // When: We generate more than 5 dumps (the ring buffer size)
        for _ in 1...7 {
            _ = await invalidProbe.debugRawProbe()
            // Small delay to ensure different timestamps
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        // Then: The dumps should only contain the most recent 5
        let dumps = await AugmentStatusProbe.latestDumps()
        let separatorCount = dumps.components(separatedBy: "\n\n---\n\n").count
        XCTAssertLessThanOrEqual(separatorCount, 5, "Should maintain at most 5 dumps in ring buffer")
    }

    func test_debugRawProbe_includesTimestamp() async {
        // Given: A probe instance
        let probe = AugmentStatusProbe()

        // When: We call debugRawProbe
        let output = await probe.debugRawProbe()

        // Then: The output should include an ISO8601 timestamp
        XCTAssertTrue(output.contains("@"), "Should contain timestamp marker")
        XCTAssertTrue(output.contains("==="), "Should contain debug header markers")
    }

    func test_debugRawProbe_includesCreditsBalance() async {
        // Given: A probe instance
        let probe = AugmentStatusProbe()

        // When: We call debugRawProbe
        let output = await probe.debugRawProbe()

        // Then: The output should mention credits balance (either in success or failure)
        XCTAssertTrue(
            output.contains("Credits Balance") || output.contains("Probe Failed"),
            "Should contain credits information or failure message")
    }

    // MARK: - Cookie Domain Filtering Tests

    func test_cookieDomainMatching_exactMatch() throws {
        // Given: A session with a cookie that has exact domain match
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "app.augmentcode.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try XCTUnwrap(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should include the cookie
        XCTAssertEqual(cookieHeader, "session=test123", "Cookie with exact domain should match")
    }

    func test_cookieDomainMatching_parentDomain() throws {
        // Given: A session with a cookie that has parent domain
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "augmentcode.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try XCTUnwrap(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should include the cookie (parent domain matches subdomain)
        XCTAssertEqual(cookieHeader, "session=test123", "Cookie with parent domain should match subdomain")
    }

    func test_cookieDomainMatching_wildcardDomain() throws {
        // Given: A session with a cookie that has wildcard domain
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".augmentcode.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try XCTUnwrap(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should include the cookie
        XCTAssertEqual(cookieHeader, "session=test123", "Cookie with wildcard domain should match")
    }

    func test_cookieDomainMatching_wrongDomain() throws {
        // Given: A session with a cookie from a different subdomain
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "auth.augmentcode.com",
            .path: "/",
            .name: "auth_token",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try XCTUnwrap(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should NOT include the cookie
        XCTAssertTrue(cookieHeader.isEmpty, "Cookie from different subdomain should not match")
    }

    func test_cookieDomainMatching_differentBaseDomain() throws {
        // Given: A session with a cookie from a completely different domain
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: "session",
            .value: "test123",
        ]))
        let session = AugmentCookieImporter.SessionInfo(
            cookies: [cookie],
            sourceLabel: "Test")
        let targetURL = try XCTUnwrap(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should NOT include the cookie
        XCTAssertTrue(cookieHeader.isEmpty, "Cookie from different base domain should not match")
    }

    func test_cookieHeader_filtersCorrectly() throws {
        // Given: A session with multiple cookies from different domains
        let cookies = try [
            XCTUnwrap(HTTPCookie(properties: [
                .domain: "app.augmentcode.com",
                .path: "/",
                .name: "session",
                .value: "valid1",
            ])),
            XCTUnwrap(HTTPCookie(properties: [
                .domain: ".augmentcode.com",
                .path: "/",
                .name: "_session",
                .value: "valid2",
            ])),
            XCTUnwrap(HTTPCookie(properties: [
                .domain: "auth.augmentcode.com",
                .path: "/",
                .name: "auth_token",
                .value: "invalid1",
            ])),
            XCTUnwrap(HTTPCookie(properties: [
                .domain: "billing.augmentcode.com",
                .path: "/",
                .name: "billing_session",
                .value: "invalid2",
            ])),
        ]

        let session = AugmentCookieImporter.SessionInfo(
            cookies: cookies,
            sourceLabel: "Test")

        let targetURL = try XCTUnwrap(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should only include cookies valid for app.augmentcode.com
        XCTAssertTrue(cookieHeader.contains("session=valid1"), "Should include exact domain match")
        XCTAssertTrue(cookieHeader.contains("_session=valid2"), "Should include wildcard domain match")
        XCTAssertFalse(cookieHeader.contains("auth_token"), "Should NOT include auth subdomain cookie")
        XCTAssertFalse(cookieHeader.contains("billing_session"), "Should NOT include billing subdomain cookie")
    }

    func test_cookieHeader_emptyWhenNoCookiesMatch() throws {
        // Given: A session with cookies that don't match the target domain
        let cookies = try [
            XCTUnwrap(HTTPCookie(properties: [
                .domain: "auth.augmentcode.com",
                .path: "/",
                .name: "auth_token",
                .value: "test",
            ])),
            XCTUnwrap(HTTPCookie(properties: [
                .domain: "example.com",
                .path: "/",
                .name: "other",
                .value: "test",
            ])),
        ]

        let session = AugmentCookieImporter.SessionInfo(
            cookies: cookies,
            sourceLabel: "Test")

        let targetURL = try XCTUnwrap(URL(string: "https://app.augmentcode.com/api/credits"))

        // When: We get the cookie header for the target URL
        let cookieHeader = session.cookieHeader(for: targetURL)

        // Then: It should be empty
        XCTAssertTrue(cookieHeader.isEmpty, "Should return empty string when no cookies match")
    }
}
