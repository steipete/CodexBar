import Foundation
import Testing
@testable import CodexBarCore

struct CodexCustomProviderCredentialsTests {
    // MARK: - TOML fragment parsing (in-memory string fixtures)

    @Test
    func `resolves base url from model provider and model_providers table`() throws {
        let toml = """
        model_provider = "OpenAI"
        model_reasoning_effort = "medium"

        [model_providers.OpenAI]
        name = "OpenAI"
        base_url = "https://example.com/v1"
        wire_api = "responses"
        """

        let url = try #require(CodexCustomProviderCredentials.baseURL(from: toml))
        #expect(url.absoluteString == "https://example.com/v1")
    }

    @Test
    func `resolves base url when provider key is quoted`() throws {
        let toml = """
        model_provider = "My Provider"
        [model_providers."My Provider"]
        base_url = "https://example.com"
        """

        let url = try #require(CodexCustomProviderCredentials.baseURL(from: toml))
        #expect(url.absoluteString == "https://example.com")
    }

    @Test
    func `strips inline comments and surrounding quotes`() throws {
        let toml = """
        model_provider = "OpenAI" # the provider to use
        [model_providers.OpenAI]
        base_url = 'https://example.com' # custom endpoint
        """

        let url = try #require(CodexCustomProviderCredentials.baseURL(from: toml))
        #expect(url.absoluteString == "https://example.com")
    }

    @Test
    func `missing model provider resolves to nil`() {
        let toml = """
        [model_providers.OpenAI]
        base_url = "https://example.com"
        """
        #expect(CodexCustomProviderCredentials.baseURL(from: toml) == nil)
    }

    @Test
    func `named provider without base url resolves to nil`() {
        let toml = """
        model_provider = "OpenAI"
        [model_providers.OpenAI]
        name = "OpenAI"
        """
        #expect(CodexCustomProviderCredentials.baseURL(from: toml) == nil)
    }

    @Test
    func `ignores base url under a different provider table`() {
        let toml = """
        model_provider = "OpenAI"
        [model_providers.Other]
        base_url = "https://wrong.com"
        [model_providers.OpenAI]
        name = "OpenAI"
        """
        #expect(CodexCustomProviderCredentials.baseURL(from: toml) == nil)
    }

    @Test
    func `model provider value inside a table is not treated as the top-level selector`() {
        // A `model_provider` key nested in a table must not be mistaken for the
        // top-level selector that names the active provider.
        let toml = """
        [profile]
        model_provider = "OpenAI"
        """
        #expect(CodexCustomProviderCredentials.modelProvider(from: toml) == nil)
    }

    @Test
    func `invalid base url string resolves to nil`() {
        let toml = """
        model_provider = "OpenAI"
        [model_providers.OpenAI]
        base_url = "not a url"
        """
        #expect(CodexCustomProviderCredentials.baseURL(from: toml) == nil)
    }

    // MARK: - resolve(env:) honors CODEX_HOME with real (temp) files

    @Test
    func `resolve reads config and auth from CODEX_HOME`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        let toml = """
        model_provider = "OpenAI"
        [model_providers.OpenAI]
        base_url = "https://example.com"
        """
        try toml.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8)
        let auth = #"{"OPENAI_API_KEY":"sk-test-123"}"#
        try auth.write(
            to: home.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8)

        let resolved = CodexCustomProviderCredentials.resolve(env: ["CODEX_HOME": home.path])
        let credentials = try #require(resolved)
        #expect(credentials.baseURL.absoluteString == "https://example.com")
        #expect(credentials.apiKey == "sk-test-123")
    }

    @Test
    func `resolve returns nil when auth json lacks OPENAI_API_KEY`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        try """
        model_provider = "OpenAI"
        [model_providers.OpenAI]
        base_url = "https://example.com"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8)
        // OAuth-style auth.json (no OPENAI_API_KEY) — custom source is unavailable.
        try #"{"tokens":{"access_token":"tok","refresh_token":"ref"}}"#.write(
            to: home.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8)

        #expect(CodexCustomProviderCredentials.resolve(env: ["CODEX_HOME": home.path]) == nil)
    }

    @Test
    func `resolve returns nil when config lacks base url`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        try "model_provider = \"OpenAI\"\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8)
        try #"{"OPENAI_API_KEY":"sk-test"}"#.write(
            to: home.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8)

        #expect(CodexCustomProviderCredentials.resolve(env: ["CODEX_HOME": home.path]) == nil)
    }

    @Test
    func `resolve returns nil when files are absent`() {
        let missingHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        #expect(CodexCustomProviderCredentials.resolve(env: ["CODEX_HOME": missingHome.path]) == nil)
    }
}
