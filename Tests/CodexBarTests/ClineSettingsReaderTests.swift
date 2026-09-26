import CodexBarCore
import Foundation
import Testing

struct ClineSettingsReaderTests {
    @Test
    func `api key reads primary then alternate environment keys`() {
        #expect(ClineSettingsReader.apiKey(environment: ["CLINE_API_KEY": "primary"]) == "primary")
        #expect(ClineSettingsReader.apiKey(environment: ["CLINEPASS_API_KEY": "alternate"]) == "alternate")
        #expect(ClineSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `resolved token prefers explicit api key over browser session`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"oauth-access"}},"updatedAt":"2026-01-01T00:00:00Z","tokenSource":"oauth"}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let env: [String: String] = [
            "CLINE_API_KEY": "explicit-key",
            ClineSettingsReader.providerSettingsPathEnvironmentKey: file.path,
        ]
        #expect(ClineSettingsReader.resolvedToken(environment: env) == "explicit-key")
        #expect(ClineSettingsReader.usesBrowserSession(environment: env) == false)
    }

    @Test
    func `auth token formats workos prefix for browser session`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"providers":{"cline":{"settings":{"auth":{"accessToken":"oauth-access","refreshToken":"refresh"}}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let env = [ClineSettingsReader.providerSettingsPathEnvironmentKey: file.path]
        #expect(ClineSettingsReader.authToken(environment: env) == "workos:oauth-access")
        #expect(ClineSettingsReader.usesBrowserSession(environment: env) == true)
    }

    @Test
    func `auth token returns nil for missing file`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("providers.json", isDirectory: false)
        #expect(ClineSettingsReader.authToken(authFileURL: url) == nil)
    }

    @Test
    func `descriptor resolves browser session as auth file credential`() throws {
        let file = try self.writeProvidersFile(contents: """
        {"providers":{"cline":{"settings":{"auth":{"accessToken":"browser-token"}}}}}
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .cline)
        let environment = [ClineSettingsReader.providerSettingsPathEnvironmentKey: file.path]
        let resolution = descriptor.credentials?.resolveToken(environment: environment)
        #expect(resolution?.token == "workos:browser-token")
        #expect(resolution?.source == .authFile)
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
