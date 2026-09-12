import Foundation
import Testing
@testable import CodexBarCore

struct NousSettingsReaderTests {
    private static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".hermes/shared", isDirectory: true),
            withIntermediateDirectories: true)
        return home
    }

    private static func write(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    private static func authJSON(token: String, expiresAt: String, portal: String = "https://portal.nousresearch.com") -> String {
        """
        {
          "version": 1,
          "providers": {
            "nous": {
              "access_token": "\(token)",
              "refresh_token": "rt",
              "portal_base_url": "\(portal)",
              "expires_at": "\(expiresAt)"
            }
          }
        }
        """
    }

    @Test
    func `environment token overrides hermes auth file`() throws {
        let home = try Self.makeHome()
        try Self.write(
            Self.authJSON(token: "file-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        let credential = try NousSettingsReader.resolveCredential(environment: [
            "HOME": home.path,
            "NOUS_PORTAL_ACCESS_TOKEN": "env-token",
            "NOUS_PORTAL_BASE_URL": "https://preview.portal.example.com/",
        ])
        #expect(credential.token == "env-token")
        #expect(credential.source == .environment)
        #expect(credential.portalBaseURL.absoluteString == "https://preview.portal.example.com")
        #expect(credential.rejectedPortalHost == nil)
    }

    @Test
    func `reads providers section from hermes auth file`() throws {
        let home = try Self.makeHome()
        let path = home.appendingPathComponent(".hermes/auth.json")
        try Self.write(Self.authJSON(token: "file-token", expiresAt: "2999-01-01T00:00:00+00:00"), to: path)

        let credential = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        #expect(credential.token == "file-token")
        #expect(credential.source == .authFile(path.path))
        #expect(credential.portalBaseURL == NousSettingsReader.defaultPortalBaseURL)
        #expect(credential.expiresAt == NousSettingsReader.parseISODate("2999-01-01T00:00:00+00:00"))
    }

    @Test
    func `HERMES_HOME override takes precedence over default home`() throws {
        let home = try Self.makeHome()
        let custom = home.appendingPathComponent("custom-hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Self.write(
            Self.authJSON(token: "default-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        try Self.write(
            Self.authJSON(token: "custom-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: custom.appendingPathComponent("auth.json"))

        let credential = try NousSettingsReader.resolveCredential(environment: [
            "HOME": home.path,
            "HERMES_HOME": custom.path,
        ])
        #expect(credential.token == "custom-token")
    }

    @Test
    func `HERMES_HOME is exclusive: a missing custom profile never falls back to the default root`() throws {
        let home = try Self.makeHome()
        let custom = home.appendingPathComponent("custom-hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Self.write(
            Self.authJSON(token: "default-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        let env = ["HOME": home.path, "HERMES_HOME": custom.path]

        #expect(NousSettingsReader.authFileCandidates(environment: env).allSatisfy { $0.path.hasPrefix(custom.path) })
        #expect(NousSettingsReader.credential(environment: env) == nil)
        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: env)
        } throws: { error in
            error as? NousUsageError == .missingCredentials
        }
    }

    @Test
    func `HERMES_HOME is exclusive: an expired custom profile reports expiry instead of another profile`() throws {
        let home = try Self.makeHome()
        let custom = home.appendingPathComponent("custom-hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Self.write(
            Self.authJSON(token: "default-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        let customAuth = custom.appendingPathComponent("auth.json")
        try Self.write(Self.authJSON(token: "stale", expiresAt: "2000-01-01T00:00:00+00:00"), to: customAuth)
        let env = ["HOME": home.path, "HERMES_HOME": custom.path]

        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: env)
        } throws: { error in
            error as? NousUsageError == .sessionExpired(customAuth.path)
        }
    }

    @Test
    func `HERMES_HOME is exclusive: an invalid custom profile reports the invalid file`() throws {
        let home = try Self.makeHome()
        let custom = home.appendingPathComponent("custom-hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Self.write(
            Self.authJSON(token: "default-token", expiresAt: "2999-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        let customAuth = custom.appendingPathComponent("auth.json")
        try Self.write("{ \"version\": 1, \"providers\": {} }", to: customAuth)
        let env = ["HOME": home.path, "HERMES_HOME": custom.path]

        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: env)
        } throws: { error in
            error as? NousUsageError == .authFileInvalid(customAuth.path)
        }
    }

    @Test
    func `falls back to shared store when profile token is expired`() throws {
        let home = try Self.makeHome()
        try Self.write(
            Self.authJSON(token: "stale", expiresAt: "2000-01-01T00:00:00+00:00"),
            to: home.appendingPathComponent(".hermes/auth.json"))
        try Self.write(
            """
            { "_schema": 1, "access_token": "shared-token", "expires_at": "2999-01-01T00:00:00+00:00" }
            """,
            to: home.appendingPathComponent(".hermes/shared/nous_auth.json"))

        let credential = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        #expect(credential.token == "shared-token")
    }

    @Test
    func `expired token reports session expired instead of missing`() throws {
        let home = try Self.makeHome()
        let path = home.appendingPathComponent(".hermes/auth.json")
        try Self.write(Self.authJSON(token: "stale", expiresAt: "2000-01-01T00:00:00+00:00"), to: path)

        #expect(NousSettingsReader.credential(environment: ["HOME": home.path]) == nil)
        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        } throws: { error in
            error as? NousUsageError == .sessionExpired(path.path)
        }
        #expect(NousSettingsReader.unavailableMessage(environment: ["HOME": home.path])?.contains("expired") == true)
    }

    @Test
    func `missing auth file reports missing credentials`() throws {
        let home = try Self.makeHome()
        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        } throws: { error in
            error as? NousUsageError == .missingCredentials
        }
    }

    @Test
    func `credential pool entries are accepted when providers section is absent`() throws {
        let data = Data("""
        {
          "credential_pool": {
            "nous": [
              { "id": "a", "auth_type": "oauth", "access_token": "pool-token", "expires_at": "2999-01-01T00:00:00+00:00" }
            ]
          }
        }
        """.utf8)
        let stored = try #require(NousSettingsReader.parseAuthFile(data: data))
        #expect(stored.token == "pool-token")
        #expect(stored.portalBaseURL == nil)
    }

    @Test
    func `jwt exp claim is used when no expiry is stored`() {
        let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        let payload = Data("{\"exp\": 946684800}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "\(header).\(payload).sig"
        #expect(NousSettingsReader.jwtExpiry(token) == Date(timeIntervalSince1970: 946_684_800))

        let credential = NousSettingsReader.Credential(
            token: token,
            portalBaseURL: NousSettingsReader.defaultPortalBaseURL,
            expiresAt: NousSettingsReader.jwtExpiry(token),
            source: .environment)
        #expect(credential.isExpired(now: Date(timeIntervalSince1970: 946_684_800 + 10)))
        #expect(!credential.isExpired(now: Date(timeIntervalSince1970: 946_684_800 - 600)))
    }

    @Test
    func `portal base URL rejects every http override including loopback`() {
        for raw in ["http://evil.example", "http://localhost:3000", "http://127.0.0.1", "ftp://portal.nousresearch.com"] {
            let override = NousSettingsReader.portalBaseURL(environment: ["NOUS_PORTAL_BASE_URL": raw], stored: nil)
            #expect(override.url == NousSettingsReader.defaultPortalBaseURL, "override \(raw) must be refused")
            #expect(override.origin == .default)

            let stored = NousSettingsReader.portalBaseURL(environment: [:], stored: raw)
            #expect(stored.url == NousSettingsReader.defaultPortalBaseURL, "stored \(raw) must be refused")
            #expect(stored.rejectedStoredHost == nil, "a non-HTTPS stored value is discarded, not treated as a host")
        }
        #expect(NousSettingsReader.normalizedHTTPSURL("http://localhost") == nil)
        #expect(NousSettingsReader.normalizedHTTPSURL("https://localhost:8443")?.absoluteString == "https://localhost:8443")
    }

    @Test
    func `stored portal host outside nousresearch.com is rejected and never receives the token`() throws {
        let untrusted = NousSettingsReader.portalBaseURL(environment: [:], stored: "https://stored.example/")
        #expect(untrusted.url == NousSettingsReader.defaultPortalBaseURL)
        #expect(untrusted.origin == .default)
        #expect(untrusted.rejectedStoredHost == "stored.example")

        let lookalike = NousSettingsReader.portalBaseURL(environment: [:], stored: "https://nousresearch.com.evil.example")
        #expect(lookalike.url == NousSettingsReader.defaultPortalBaseURL)
        #expect(lookalike.rejectedStoredHost == "nousresearch.com.evil.example")

        let home = try Self.makeHome()
        let path = home.appendingPathComponent(".hermes/auth.json")
        try Self.write(
            Self.authJSON(token: "file-token", expiresAt: "2999-01-01T00:00:00+00:00", portal: "https://stored.example"),
            to: path)
        let credential = try NousSettingsReader.resolveCredential(environment: ["HOME": home.path])
        #expect(credential.portalBaseURL == NousSettingsReader.defaultPortalBaseURL)
        #expect(credential.rejectedPortalHost == "stored.example")
        #expect(NousUsageFetcher.accountURL(portalBaseURL: credential.portalBaseURL).host == "portal.nousresearch.com")
    }

    @Test
    func `stored nousresearch.com preview hosts are trusted`() {
        let preview = NousSettingsReader.portalBaseURL(environment: [:], stored: "https://preview.portal.nousresearch.com/")
        #expect(preview.url.absoluteString == "https://preview.portal.nousresearch.com")
        #expect(preview.origin == .storedTrusted)
        #expect(preview.rejectedStoredHost == nil)
        #expect(NousSettingsReader.isTrustedPortalHost("portal.nousresearch.com"))
        #expect(NousSettingsReader.isTrustedPortalHost("NousResearch.com"))
        #expect(!NousSettingsReader.isTrustedPortalHost("evilnousresearch.com"))
        #expect(!NousSettingsReader.isTrustedPortalHost(nil))
    }

    @Test
    func `environment override remains explicit and takes precedence over a stored host`() {
        let resolution = NousSettingsReader.portalBaseURL(
            environment: ["NOUS_PORTAL_BASE_URL": "https://preview.portal.example.com"],
            stored: "https://portal.nousresearch.com")
        #expect(resolution.url.absoluteString == "https://preview.portal.example.com")
        #expect(resolution.origin == .environmentOverride)
    }

    @Test
    func `expired environment token is rejected before any request`() {
        let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        let payload = Data("{\"exp\": 946684800}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let env = ["HOME": "/nonexistent", "NOUS_PORTAL_ACCESS_TOKEN": "\(header).\(payload).sig"]
        #expect(NousSettingsReader.credential(environment: env) == nil)
        #expect {
            _ = try NousSettingsReader.resolveCredential(environment: env)
        } throws: { error in
            error as? NousUsageError == .environmentTokenExpired
        }
    }
}
