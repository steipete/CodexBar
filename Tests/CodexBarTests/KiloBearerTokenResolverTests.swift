import Foundation
import Testing
@testable import CodexBarCore

struct KiloBearerTokenResolverTests {
    private func writeAuthFile(_ json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilo-resolver-tests-\(UUID().uuidString)", isDirectory: true)
        let kiloDir = directory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("kilo", isDirectory: true)
        try FileManager.default.createDirectory(at: kiloDir, withIntermediateDirectories: true)
        let authURL = kiloDir.appendingPathComponent("auth.json", isDirectory: false)
        try json.write(to: authURL, atomically: true, encoding: .utf8)
        return directory
    }

    @Test
    func `api mode uses provided apiKey`() throws {
        let resolved = try KiloBearerTokenResolver.resolve(
            source: .api,
            apiKey: "kilo_abc",
            environment: [:])
        #expect(resolved.token == "kilo_abc")
        #expect(resolved.sourceLabel == "api")
    }

    @Test
    func `api mode falls back to KILO_API_KEY env var when apiKey is empty`() throws {
        let resolved = try KiloBearerTokenResolver.resolve(
            source: .api,
            apiKey: nil,
            environment: ["KILO_API_KEY": "kilo_from_env"])
        #expect(resolved.token == "kilo_from_env")
        #expect(resolved.sourceLabel == "api")
    }

    @Test
    func `api mode throws missingCredentials when nothing available`() {
        #expect(throws: KiloUsageError.missingCredentials) {
            try KiloBearerTokenResolver.resolve(
                source: .api,
                apiKey: nil,
                environment: [:])
        }
    }

    @Test
    func `cli mode reads token from auth.json`() throws {
        let home = try self.writeAuthFile(#"{ "kilo": { "access": "cli-token" } }"#)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = try KiloBearerTokenResolver.resolve(
            source: .cli,
            apiKey: nil,
            environment: ["HOME": home.path])
        #expect(resolved.token == "cli-token")
        #expect(resolved.sourceLabel == "cli")
    }

    @Test
    func `cli mode throws cliSessionMissing when auth.json missing`() {
        let nonexistentHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilo-no-such-home-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: (any Error).self) {
            try KiloBearerTokenResolver.resolve(
                source: .cli,
                apiKey: nil,
                environment: ["HOME": nonexistentHome.path])
        }
    }

    @Test
    func `cli mode throws cliSessionInvalid for malformed JSON`() throws {
        let home = try self.writeAuthFile(#"{ "kilo": { } }"#)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(throws: (any Error).self) {
            try KiloBearerTokenResolver.resolve(
                source: .cli,
                apiKey: nil,
                environment: ["HOME": home.path])
        }
    }

    @Test
    func `auto mode prefers API key when available`() throws {
        let home = try self.writeAuthFile(#"{ "kilo": { "access": "cli-token" } }"#)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = try KiloBearerTokenResolver.resolve(
            source: .auto,
            apiKey: "kilo_api",
            environment: ["HOME": home.path])
        #expect(resolved.token == "kilo_api")
        #expect(resolved.sourceLabel == "api")
    }

    @Test
    func `auto mode falls back to CLI when API key missing`() throws {
        let home = try self.writeAuthFile(#"{ "kilo": { "access": "cli-fallback" } }"#)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = try KiloBearerTokenResolver.resolve(
            source: .auto,
            apiKey: nil,
            environment: ["HOME": home.path])
        #expect(resolved.token == "cli-fallback")
        #expect(resolved.sourceLabel == "cli")
    }

    @Test
    func `auto mode surfaces CLI error when neither path available`() {
        let nonexistentHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilo-no-such-home-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: (any Error).self) {
            try KiloBearerTokenResolver.resolve(
                source: .auto,
                apiKey: nil,
                environment: ["HOME": nonexistentHome.path])
        }
    }
}
