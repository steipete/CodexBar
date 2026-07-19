import CodexBarCore
import Foundation
import Testing

struct CodebuffSettingsReaderTests {
    @Test
    func `api URL defaults to www codebuff com`() {
        let url = CodebuffSettingsReader.apiURL(environment: [:])
        #expect(url.scheme == "https")
        #expect(url.host() == "www.codebuff.com")
    }

    @Test
    func `api URL honors environment override`() {
        let url = CodebuffSettingsReader.apiURL(environment: [
            "CODEBUFF_API_URL": "https://staging.codebuff.com",
        ])
        #expect(url.host() == "staging.codebuff.com")
    }

    @Test
    func `api key reads from CODEBUFF_API_KEY and trims wrapping whitespace`() {
        let token = CodebuffSettingsReader.apiKey(environment: [
            CodebuffSettingsReader.apiTokenKey: "  cb-test-token  ",
        ])
        #expect(token == "cb-test-token")
    }

    @Test
    func `api key strips surrounding quotes`() {
        let token = CodebuffSettingsReader.apiKey(environment: [
            CodebuffSettingsReader.apiTokenKey: "\"cb-test-token\"",
        ])
        #expect(token == "cb-test-token")
    }

    @Test
    func `api key returns nil for empty environment`() {
        #expect(CodebuffSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `auth token parses credentials json`() throws {
        let contents = #"{"authToken":"file-token","fingerprintId":"fp-1","email":"a@b.com"}"#
        let url = try self.writeTempFile(named: "credentials.json", contents: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let token = CodebuffSettingsReader.authToken(authFileURL: url)
        #expect(token == "file-token")
    }

    @Test
    func `auth token parses default profile credentials json`() throws {
        let contents = #"{"default":{"authToken":"default-token","fingerprintId":"fp-1","email":"a@b.com"}}"#
        let url = try self.writeTempFile(named: "credentials.json", contents: contents)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let token = CodebuffSettingsReader.authToken(authFileURL: url)
        #expect(token == "default-token")
    }

    @Test
    func `auth token returns nil for malformed credentials json`() throws {
        let url = try self.writeTempFile(named: "credentials.json", contents: "{not-json}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let token = CodebuffSettingsReader.authToken(authFileURL: url)
        #expect(token == nil)
    }

    @Test
    func `auth token returns nil when file missing`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
        #expect(CodebuffSettingsReader.authToken(authFileURL: url) == nil)
    }

    @Test
    func `descriptor uses codebuff dashboard URL`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codebuff)
        #expect(descriptor.metadata.dashboardURL == "https://www.codebuff.com/usage")
        #expect(descriptor.metadata.displayName == "Codebuff")
        #expect(descriptor.metadata.cliName == "codebuff")
    }

    @Test
    func `descriptor uses dedicated codebuff icon resource`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codebuff)
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-codebuff")
    }

    @Test
    func `descriptor supports auto and API source modes`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codebuff)
        let expected: Set<ProviderSourceMode> = [.auto, .api]
        #expect(descriptor.fetchPlan.sourceModes == expected)
    }

    // MARK: - Helpers

    private func writeTempFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
