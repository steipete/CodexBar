import Foundation
import Testing
@testable import CodexBarCore

struct MuseCredentialsTests {
    @Test
    func `Keychain payload selects the device token rather than the inference key`() throws {
        let data = Data(#"{"api_key":"LLM|fixture-inference","access_token":"dca:fixture-device"}"#.utf8)
        #expect(try MuseCredentials.accessToken(fromKeychainPayload: data) == "dca:fixture-device")
    }

    @Test(arguments: [
        #"{"api_key":"LLM|fixture-inference"}"#, #"{"access_token":"LLM|fixture-inference"}"#,
        #"{"access_token":""}"#, #"{"access_token":"   "}"#,
    ])
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
    func `Keychain-backed login names the Settings toggle when Keychain access is disabled`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#.utf8).write(to: file)

        let message = KeychainAccessGate.withTaskOverrideForTesting(true) {
            do {
                _ = try MuseCredentials.accessToken(
                    environment: ["MUSE_AUTH_PATH": file.path],
                    homeDirectory: directory)
                Issue.record("Expected disabled Keychain access to reject the credential read")
                return ""
            } catch {
                return error.localizedDescription
            }
        }
        #expect(message.contains("Disable Keychain access"))
        #expect(message.contains("Settings"))
    }

    @Test
    func `missing login does not mention Keychain when access is disabled`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{}"#.utf8).write(to: file)

        KeychainAccessGate.withTaskOverrideForTesting(true) {
            #expect(throws: MuseUsageError.missingCredentials) {
                try MuseCredentials.accessToken(
                    environment: ["MUSE_AUTH_PATH": file.path],
                    homeDirectory: directory)
            }
        }
    }

    @Test
    func `prompt-required Keychain error stays distinct from the disabled-access toggle`() throws {
        let message = try #require(MuseUsageError.keychainUnavailable.errorDescription)
        #expect(message.contains("could not be read without a prompt"))
        #expect(!message.contains("Disable Keychain access"))
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

    @Test
    func `default credential path stays under the supplied home`() {
        let home = URL(fileURLWithPath: "/synthetic/home", isDirectory: true)
        #expect(MuseCredentials.authFileURL(environment: [:], homeDirectory: home) ==
            URL(fileURLWithPath: "/synthetic/home/.config/muse/auth.json"))
    }
}
