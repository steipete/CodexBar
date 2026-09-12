import Foundation
import Testing
@testable import CodexBarCore

struct CodexNativeJWTExpiryTests {
    @Test(arguments: ["-8334601228800", "-1", "-0", "0", "1", "4102444800", "8210266876799"])
    func `accepts signed integer spellings within the Codex date range`(_ raw: String) throws {
        let credentials = try Self.credentials(payload: #"{"exp":\#(raw)}"#)
        let integer = try #require(Int64(raw))
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: Double(integer)))
        #expect(credentials.needsRefresh == (integer <= 1))
    }

    @Test(arguments: [
        "true", "false", "null", #""4102444800""#, "[]", "{}",
        "1.5", "-1.5", "0.0", "-0.0", "1.0", "4102444800.0",
        "1e0", "1E0", "4102444800e0", "4102444800E+0", "41024448000e-1",
        "4.1024448e9", "1e309", "1e-999",
        "9223372036854775807", "9223372036854775808", "18446744073709551616",
        "-9223372036854775808", "-9223372036854775809",
        "-8334601228801", "8210266876800",
    ])
    func `rejected raw claim spellings retain timestamp freshness`(_ raw: String) throws {
        for lastRefresh in [nil, "invalid", "2000-01-01T00:00:00Z", Self.freshTimestamp] {
            let credentials = try Self.credentials(payload: #"{"exp":\#(raw)}"#, lastRefresh: lastRefresh)
            #expect(credentials.expiresAt == nil)
            #expect(credentials.needsRefresh == (lastRefresh != Self.freshTimestamp))
        }
    }

    @Test(arguments: [
        "{}", #"{"nested":{"exp":4102444800}}"#, #"{"exp":[4102444800]}"#,
        #"{"exp":{"exp":4102444800}}"#, #"{"note":"\"exp\":4102444800"}"#,
        #"{"exp":4102444800,"exp":0}"#, #"{"exp":0,"exp":4102444800}"#,
        #"{"exp":null,"exp":4102444800}"#, #"{"exp":4102444800,"\u0065xp":0}"#,
        "[]", "null", "not-json", #"{"exp":4102444800"#, #"{"exp":+1}"#, #"{"exp":01}"#,
    ])
    func `absent malformed nested and ambiguous claims fail soft`(_ payload: String) throws {
        for lastRefresh in [nil, "invalid", "2000-01-01T00:00:00Z", Self.freshTimestamp] {
            let credentials = try Self.credentials(payload: payload, lastRefresh: lastRefresh)
            #expect(credentials.expiresAt == nil)
            #expect(credentials.needsRefresh == (lastRefresh != Self.freshTimestamp))
        }
    }

    @Test(arguments: [
        #"{"\u0065xp":4102444800}"#,
        #"{"nested":[{"exp":0},1.0],"note":"exp \" [ }","exp":4102444800,"after":1e0}"#,
        #"{"exp":4102444800,"nested":{"exp":0},"note":"\"exp\":0"}"#,
    ])
    func `only the top level expiration spelling matters`(_ payload: String) throws {
        let credentials = try Self.credentials(payload: payload)
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(!credentials.needsRefresh)
    }

    @Test(arguments: ["opaque", "a.%%%.c", "a..c", ".e30.c", "a.e30.", "a.e30.c.extra"])
    func `opaque and malformed tokens retain the age fallback`(_ accessToken: String) throws {
        for lastRefresh in [nil, "invalid", "2000-01-01T00:00:00Z", Self.freshTimestamp] {
            let credentials = try Self.credentials(accessToken: accessToken, lastRefresh: lastRefresh)
            #expect(credentials.expiresAt == nil)
            #expect(credentials.needsRefresh == (lastRefresh != Self.freshTimestamp))
        }
    }

    @Test(arguments: [nil, "invalid", "2000-01-01T00:00:00Z", "2100-01-01T00:00:00Z"])
    func `expiry precedes every timestamp state`(_ lastRefresh: String?) throws {
        let future = try Self.credentials(payload: #"{"exp":4102444800}"#, lastRefresh: lastRefresh)
        let expired = try Self.credentials(payload: #"{"exp":0}"#, lastRefresh: lastRefresh)
        #expect(!future.needsRefresh)
        #expect(expired.needsRefresh)
    }

    @Test(arguments: ["2100-01-01T00:00:00Z", "2100-01-01T00:00:00.123Z"])
    func `opaque tokens keep fractional and whole second timestamps`(_ lastRefresh: String) throws {
        let credentials = try Self.credentials(accessToken: "opaque", lastRefresh: lastRefresh)
        #expect(credentials.lastRefresh != nil)
        #expect(!credentials.needsRefresh)
    }

    @Test
    func `expiry does not validate headers signatures or change account recovery`() throws {
        let payload = Data(#"{"exp":4102444800,"chatgpt_account_id":"fixture-account"}"#.utf8)
            .base64EncodedString()
        let unverified = try Self.credentials(accessToken: "%%.\(payload).%%")
        #expect(unverified.expiresAt != nil)
        #expect(unverified.accountId == "fixture-account")
        for accessToken in [".\(payload).signature", "header.\(payload)."] {
            let credentials = try Self.credentials(accessToken: accessToken)
            #expect(credentials.expiresAt == nil)
            #expect(credentials.accountId == "fixture-account")
        }
    }

    @Test(arguments: [CodexOAuthCredentialSource.codexHome, .legacyCodexHome, .openCode])
    func `native and external scheduling windows remain distinct`(_ source: CodexOAuthCredentialSource) {
        for seconds in [-1.0, 30, 120, 600] {
            let credentials = CodexOAuthCredentials(
                accessToken: "fixture",
                refreshToken: "fixture",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil,
                expiresAt: Date(timeIntervalSinceNow: seconds),
                source: source)
            #expect(credentials.needsRefresh == (seconds < (source == .codexHome ? 300 : 60)))
        }
    }

    @Test(arguments: [nil, "2000-01-01T00:00:00Z", "2100-01-01T00:00:00Z"], ["0", "4102444800"])
    func `legacy token expiry never overrides its timestamp`(_ lastRefresh: String?, _ expiration: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".config/codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = Self.jwt(#"{"exp":\#(expiration)}"#)
        let data = try Self.authData(accessToken: token, lastRefresh: lastRefresh)
        try data.write(to: directory.appendingPathComponent("auth.json"))
        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: [:], homeDirectory: root, allowExternalSources: true)
        #expect(credentials.source == .legacyCodexHome)
        #expect(credentials.expiresAt == nil)
        #expect(credentials.needsRefresh == (lastRefresh != Self.freshTimestamp))
    }

    @Test
    func `OpenCode keeps its explicit milliseconds rather than JWT expiry`() throws {
        let token = Self.jwt(#"{"exp":0}"#)
        let data = try JSONSerialization.data(withJSONObject: [
            "openai": ["type": "oauth", "access": token, "expires": 4_102_444_800_000] as [String: Any],
        ])
        let credentials = try CodexOAuthCredentialsStore._parseOpenCodeForTesting(data: data)
        #expect(credentials.source == .openCode)
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(!credentials.needsRefresh)
    }

    @Test
    func `ID token expiry is not an access token scheduling hint`() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "accessToken": "opaque",
                "refreshToken": "fixture-refresh",
                "idToken": Self.jwt(#"{"exp":4102444800,"chatgpt_account_id":"fixture-id-account"}"#),
            ],
            "last_refresh": "2000-01-01T00:00:00Z",
        ])
        let credentials = try CodexOAuthCredentialsStore.parse(data: data)
        #expect(credentials.expiresAt == nil)
        #expect(credentials.needsRefresh)
        #expect(credentials.accountId == "fixture-id-account")
    }

    @Test
    func `API keys and PAT parsing retain precedence over expiring OAuth tokens`() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "OPENAI_API_KEY": "fixture-api-key",
            "personal_access_token": "fixture-pat",
            "tokens": ["access_token": Self.jwt(#"{"exp":0}"#), "refresh_token": "fixture-refresh"],
        ])
        let credentials = try CodexOAuthCredentialsStore.parse(data: data)
        #expect(credentials.isAPIKey)
        #expect(credentials.accessToken == "fixture-api-key")
        #expect(credentials.expiresAt == nil)
        #expect(!credentials.needsRefresh)
        #expect(try CodexOAuthCredentialsStore.parsePAT(data: data).token == "fixture-pat")
    }

    private static let freshTimestamp = "2100-01-01T00:00:00Z"

    private static func jwt(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "fixture.\(encoded).signature"
    }

    private static func credentials(
        payload: String,
        lastRefresh: String? = nil) throws -> CodexOAuthCredentials
    {
        try self.credentials(accessToken: self.jwt(payload), lastRefresh: lastRefresh)
    }

    private static func credentials(
        accessToken: String,
        lastRefresh: String? = nil) throws -> CodexOAuthCredentials
    {
        try CodexOAuthCredentialsStore.parse(data: self.authData(accessToken: accessToken, lastRefresh: lastRefresh))
    }

    private static func authData(accessToken: String, lastRefresh: String?) throws -> Data {
        var payload: [String: Any] = [
            "tokens": ["access_token": accessToken, "refresh_token": "fixture-refresh"],
        ]
        payload["last_refresh"] = lastRefresh
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
