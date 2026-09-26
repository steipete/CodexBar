import CodexBarCore
import Foundation
import Testing

struct ClinePassSettingsReaderTests {
    @Test
    func `api key reads primary then alternate environment keys`() {
        #expect(ClinePassSettingsReader.apiKey(environment: ["CLINE_API_KEY": "primary"]) == "primary")
        #expect(ClinePassSettingsReader.apiKey(environment: ["CLINEPASS_API_KEY": "alternate"]) == "alternate")
        #expect(ClinePassSettingsReader.apiKey(environment: [
            "CLINE_API_KEY": "primary",
            "CLINEPASS_API_KEY": "alternate",
        ]) == "primary")
        #expect(ClinePassSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `resolved token prefers explicit api key over browser session`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"oauth-access"}},"updatedAt":"2026-01-01T00:00:00Z","tokenSource":"oauth"}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let env: [String: String] = [
            "CLINE_API_KEY": "explicit-key",
            ClinePassSettingsReader.providerSettingsPathEnvironmentKey: file.path,
        ]
        #expect(ClinePassSettingsReader.resolvedToken(environment: env) == "explicit-key")
        #expect(ClinePassSettingsReader.usesBrowserSession(environment: env) == false)
    }

    @Test
    func `auth token formats workos prefix for browser session`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"oauth-access","refreshToken":"refresh"}},"updatedAt":"2026-01-01T00:00:00Z","tokenSource":"oauth"}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let env = [ClinePassSettingsReader.providerSettingsPathEnvironmentKey: file.path]
        #expect(ClinePassSettingsReader.authToken(environment: env) == "workos:oauth-access")
        #expect(ClinePassSettingsReader.resolvedToken(environment: env) == "workos:oauth-access")
        #expect(ClinePassSettingsReader.usesBrowserSession(environment: env) == true)
    }

    @Test
    func `auth token does not double prefix workos tokens`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"providers":{"cline":{"settings":{"auth":{"accessToken":"workos:already-prefixed"}}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let env = [ClinePassSettingsReader.providerSettingsPathEnvironmentKey: file.path]
        #expect(ClinePassSettingsReader.authToken(environment: env) == "workos:already-prefixed")
    }

    @Test
    func `auth token falls back to stored api key`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"providers":{"cline":{"settings":{"apiKey":"stored-api-key"}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let env = [ClinePassSettingsReader.providerSettingsPathEnvironmentKey: file.path]
        #expect(ClinePassSettingsReader.authToken(environment: env) == "stored-api-key")
        #expect(ClinePassSettingsReader.resolvedCredential(environment: env) == .init(
            token: "stored-api-key",
            isOAuth: false))
        #expect(ClinePassSettingsReader.usesBrowserSession(environment: env) == false)
    }

    @Test
    func `stored api key in file reports api source not browser`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"providers":{"cline":{"settings":{"apiKey":"stored-api-key"}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let credential = ClinePassSettingsReader.resolvedCredential(authFileURL: file)
        #expect(credential?.token == "stored-api-key")
        #expect(credential?.isOAuth == false)
    }

    @Test
    func `auth token returns nil for missing file`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("providers.json", isDirectory: false)
        #expect(ClinePassSettingsReader.authToken(authFileURL: url) == nil)
        #expect(ClinePassSettingsReader.authToken(environment: [
            ClinePassSettingsReader.providerSettingsPathEnvironmentKey: url.path,
        ]) == nil)
    }

    @Test
    func `auth token returns nil for malformed json`() throws {
        let file = try self.writeProvidersFile(contents: "{not-json}")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(ClinePassSettingsReader.authToken(authFileURL: file) == nil)
    }

    @Test
    func `providers file respects cline data dir and cline dir overrides`() {
        let home = URL(fileURLWithPath: "/tmp/home-test", isDirectory: true)
        let dataDirURL = ClinePassSettingsReader.providersFileURL(
            environment: ["CLINE_DATA_DIR": "/tmp/custom-data"],
            homeDirectory: home)
        #expect(dataDirURL.path == "/tmp/custom-data/settings/providers.json")

        let clineDirURL = ClinePassSettingsReader.providersFileURL(
            environment: ["CLINE_DIR": "/tmp/custom-cline"],
            homeDirectory: home)
        #expect(clineDirURL.path == "/tmp/custom-cline/data/settings/providers.json")

        let defaultURL = ClinePassSettingsReader.providersFileURL(environment: [:], homeDirectory: home)
        #expect(defaultURL.path == "/tmp/home-test/.cline/data/settings/providers.json")
    }

    @Test
    func `descriptor resolves browser session through fetch values`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"providers":{"cline":{"settings":{"auth":{"accessToken":"browser-token"}}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .clinepass)
        let environment = [ClinePassSettingsReader.providerSettingsPathEnvironmentKey: file.path]
        // Token resolver reports the browser session as an auth-file credential.
        let resolution = descriptor.credentials?.resolveToken(environment: environment)
        #expect(resolution?.token == "workos:browser-token")
        #expect(resolution?.source == .authFile)
        // Diagnostics report browser sessions as OAuth, not API-key auth.
        let summary = descriptor.credentials?.diagnosticAuthSummary(
            account: nil,
            config: nil,
            environment: environment,
            settings: nil)
        #expect(summary?.configured == true)
        #expect(summary?.modes == ["oauth"])
    }

    @Test
    func `diagnostics report explicit api key as api`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .clinepass)
        let summary = descriptor.credentials?.diagnosticAuthSummary(
            account: nil,
            config: nil,
            environment: ["CLINE_API_KEY": "token"],
            settings: nil)
        #expect(summary?.modes == ["api"])
    }

    private func writeProvidersFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("providers.json", isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
