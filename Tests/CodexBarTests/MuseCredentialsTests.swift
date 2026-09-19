import Foundation
import Testing
@testable import CodexBarCore

struct MuseCredentialsTests {
    @Test
    func `Keychain payload selects the device token rather than the inference key`() throws {
        let data = Data(#"{"api_key":"LLM|fixture-inference","access_token":"dca:fixture-device"}"#.utf8)
        #expect(try MuseCredentials.accessToken(fromKeychainPayload: data) == "dca:fixture-device")
    }

    @Test(arguments: [#"{"api_key":"LLM|fixture-inference"}"#, #"{"access_token":"LLM|fixture-inference"}"#])
    func `Keychain payloads without a device token are rejected`(body: String) throws {
        #expect(throws: MuseUsageError.invalidCredentials) {
            try MuseCredentials.accessToken(fromKeychainPayload: Data(body.utf8))
        }
    }

    @Test
    func `inline CLI token is selected without any Keychain read`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"providers":{"meta":{"mechanism":"oauth","access_token":"dca:fixture-file"}}}"#.utf8)
            .write(to: file)
        let environment = ["MUSE_AUTH_PATH": file.path]
        #expect(MuseCredentials.hasLogin(environment: environment, homeDirectory: directory))
        #expect(try MuseCredentials
            .accessToken(environment: environment, homeDirectory: directory) == "dca:fixture-file")
    }

    @Test
    func `oauth metadata identifies a Keychain-backed login`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#.utf8).write(to: file)
        #expect(MuseCredentials.hasLogin(environment: ["MUSE_AUTH_PATH": file.path], homeDirectory: directory))
    }

    @Test
    func `invalid inline credentials cannot fall through to another Keychain login`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"providers":{"meta":{"mechanism":"oauth","access_token":"LLM|fixture-wrong-kind"}}}"#.utf8)
            .write(to: file)
        #expect(throws: MuseUsageError.invalidCredentials) {
            try MuseCredentials.accessToken(environment: ["MUSE_AUTH_PATH": file.path], homeDirectory: directory)
        }
    }

    @Test
    func `descriptor exposes subscription OAuth without an API-key override`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .muse)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.fetchPlan.sourceModes == Set([.auto, .oauth]))
        #expect(descriptor.credentials?.supportsAPIKeyOverride == false)
        #expect(descriptor.cli.aliases == ["muse-code"])
    }
}
