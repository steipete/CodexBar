import CodexBarCore
import Commander
import Testing
@testable import CodexBarCLI

struct FactoryAPIKeyGuidanceTests {
    @Test
    func `missing API key guidance advertises a usable stdin command`() throws {
        let message = try #require(FactoryStatusProbeError.missingAPIKey.errorDescription)
        let command = try #require(message.split(separator: "`").dropFirst().first)
        let arguments = command.split(separator: " ").map(String.init)
        #expect(arguments.first == "codexbar")

        let program = Program(descriptors: CodexBarCLI.commandDescriptors(for: "config"))
        let invocation = try program.resolve(arguments: Array(arguments.dropFirst()))

        #expect(invocation.path == ["config", "set-api-key"])
        #expect(invocation.parsedValues.options["provider"] == ["factory"])
        #expect(invocation.parsedValues.flags.contains("stdin"))
        #expect(invocation.parsedValues.options["apiKey"] == nil)
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .factory))
    }
}
