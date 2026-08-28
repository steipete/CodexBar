import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CodexCLIBackendConfigurationTests {
    private static let authenticationError =
        "Codex connection failed: codex account authentication required to read rate limits"

    @Test
    func `amazon bedrock config produces rate limit guidance without login instruction`() throws {
        let config = try Self.fixture(named: "codex-config-amazon-bedrock")

        let error = try #require(CodexCLIBackendRateLimitError.classify(
            errorDescription: Self.authenticationError,
            configContents: config))
        let message = try #require(CodexUIErrorMapper.userFacingMessage(error.localizedDescription))

        #expect(error == .chatGPTRateLimitsUnavailable(.amazonBedrock))
        #expect(
            message ==
                "Codex is configured for Amazon Bedrock; ChatGPT rate limits are unavailable. " +
                "Disable the Codex usage card or use cost-based tracking.")
        #expect(!message.contains("codex login"))
        #expect(!message.contains("device-auth"))
    }

    @Test
    func `normal openai config keeps authentication failure unchanged`() throws {
        let config = try Self.fixture(named: "codex-config-openai")

        let classified = CodexCLIBackendRateLimitError.classify(
            errorDescription: Self.authenticationError,
            configContents: config)

        #expect(classified == nil)
        #expect(
            CodexUIErrorMapper.userFacingMessage(Self.authenticationError) ==
                "Codex CLI is not signed in. Run `codex login --device-auth`, then refresh.")
    }

    private static func fixture(named name: String) throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "toml",
            subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
