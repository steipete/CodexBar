import Foundation
import Testing
@testable import CodexBarCore

struct HuggingFaceSettingsReaderTests {
    @Test
    func `config key takes precedence over vendor environment keys`() {
        let environment = [
            "CODEXBAR_HUGGINGFACE_API_KEY": "hf_config",
            "HF_TOKEN": "hf_env",
            "HUGGING_FACE_HUB_TOKEN": "hf_legacy",
        ]
        #expect(HuggingFaceSettingsReader.apiKey(
            environment: environment,
            homeDirectory: Self.emptyHome()) == "hf_config")
    }

    @Test
    func `hf token wins over legacy hub token`() {
        let environment = [
            "HF_TOKEN": "hf_env",
            "HUGGING_FACE_HUB_TOKEN": "hf_legacy",
        ]
        #expect(HuggingFaceSettingsReader.apiKey(
            environment: environment,
            homeDirectory: Self.emptyHome()) == "hf_env")
    }

    @Test
    func `legacy hub token is used when hf token is missing`() {
        let environment = ["HUGGING_FACE_HUB_TOKEN": "hf_legacy"]
        #expect(HuggingFaceSettingsReader.apiKey(
            environment: environment,
            homeDirectory: Self.emptyHome()) == "hf_legacy")
    }

    @Test
    func `strips matched quotes and whitespace`() {
        let environment = ["HF_TOKEN": "  \"hf_quoted\"  "]
        #expect(HuggingFaceSettingsReader.apiKey(
            environment: environment,
            homeDirectory: Self.emptyHome()) == "hf_quoted")
    }

    @Test
    func `reads cli token file when environment is empty`() throws {
        let home = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeTokenFile(
            at: home.appendingPathComponent(".cache/huggingface/token"),
            contents: "hf_from_file\n")

        #expect(HuggingFaceSettingsReader.apiKey(environment: [:], homeDirectory: home) == "hf_from_file")
    }

    @Test
    func `hf token path override wins over hf home`() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let explicit = directory.appendingPathComponent("explicit-token")
        try Self.writeTokenFile(at: explicit, contents: "hf_explicit")
        try Self.writeTokenFile(
            at: directory.appendingPathComponent("hf-home/token"),
            contents: "hf_home_token")

        let environment = [
            "HF_TOKEN_PATH": explicit.path,
            "HF_HOME": directory.appendingPathComponent("hf-home").path,
        ]
        #expect(HuggingFaceSettingsReader.apiKey(
            environment: environment,
            homeDirectory: Self.emptyHome()) == "hf_explicit")
    }

    @Test
    func `hf home override points at its token file`() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeTokenFile(
            at: directory.appendingPathComponent("hf-home/token"),
            contents: "hf_home_token")

        let environment = ["HF_HOME": directory.appendingPathComponent("hf-home").path]
        #expect(HuggingFaceSettingsReader.apiKey(
            environment: environment,
            homeDirectory: Self.emptyHome()) == "hf_home_token")
    }

    @Test
    func `returns nil when nothing is configured`() throws {
        let home = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HuggingFaceSettingsReader.apiKey(environment: [:], homeDirectory: home) == nil)
    }

    @Test
    func `token file uses only its first line`() throws {
        let home = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeTokenFile(
            at: home.appendingPathComponent(".cache/huggingface/token"),
            contents: "hf_first\ngarbage-second-line\n")

        #expect(HuggingFaceSettingsReader.apiKey(environment: [:], homeDirectory: home) == "hf_first")
    }

    // MARK: - Helpers

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func emptyHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-missing-home-\(UUID().uuidString)", isDirectory: true)
    }

    private static func writeTokenFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
