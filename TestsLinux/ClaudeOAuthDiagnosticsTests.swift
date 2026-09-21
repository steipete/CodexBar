import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthDiagnosticsTests {
    private func credentials(expiry: String) throws -> ClaudeOAuthCredentials {
        try ClaudeOAuthCredentials.parse(data: Data("""
        {"claudeAiOauth":{"accessToken":"test-token","expiresAt":\(expiry),"scopes":["user:profile"]}}
        """.utf8))
    }

    @Test(arguments: [("1e30", "false"), ("-1e30", "true"), ("1e308", "false")])
    func `oversized parsed expiries remain safe to diagnose`(expiry: String, expired: String) throws {
        let credentials = try self.credentials(expiry: expiry)
        let metadata = credentials.diagnosticsMetadata(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(credentials.expiresAt != nil)
        #expect(metadata["expiresAtMs"] == "out_of_range")
        #expect(metadata["expiresInSec"] == "out_of_range")
        #expect(metadata["isExpired"] == expired)
        #expect(metadata["hasUserProfileScope"] == "true")
        #expect(!metadata.values.contains(credentials.accessToken))
    }

    @Test
    func `integer boundary overflow only omits the unrepresentable diagnostic`() throws {
        let credentials = try self.credentials(expiry: String(Int.max))
        let metadata = credentials.diagnosticsMetadata(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(metadata["expiresAtMs"] == "out_of_range")
        #expect(metadata["expiresInSec"].flatMap(Int.init) != nil)
        #expect(metadata["isExpired"] == "false")
    }

    @Test(arguments: [(1_999_999_999.5, "1", "false"), (2_000_000_001.0, "-1", "true")])
    func `normal expiry diagnostics preserve truncation rounding and expiry state`(
        now: Double, remaining: String, expired: String) throws
    {
        let credentials = try self.credentials(expiry: "2000000000123.75")
        let metadata = credentials.diagnosticsMetadata(now: Date(timeIntervalSince1970: now))
        #expect(metadata["expiresAtMs"] == "2000000000123")
        #expect(metadata["expiresInSec"] == remaining)
        #expect(metadata["isExpired"] == expired)
    }

    @Test(arguments: [Double.infinity, -.infinity, .nan, .greatestFiniteMagnitude])
    func `nonfinite or overflowing diagnostic arithmetic does not trap`(expiry: Double) {
        let credentials = ClaudeOAuthCredentials(
            accessToken: "test-token",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: expiry),
            scopes: [],
            rateLimitTier: nil)
        let metadata = credentials.diagnosticsMetadata(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(metadata["expiresAtMs"] == "out_of_range")
        #expect(metadata["expiresInSec"] == "out_of_range")
    }

    @Test
    func `missing expiry remains distinct from an out of range expiry`() throws {
        let credentials = try self.credentials(expiry: "null")
        let metadata = credentials.diagnosticsMetadata()
        #expect(metadata["expiresAtMs"] == "nil")
        #expect(metadata["expiresInSec"] == "nil")
        #expect(metadata["isExpired"] == "true")
    }
}
