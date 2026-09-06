import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct CodexRPCLoggingTests {
    @Test
    func `Codex RPC diagnostics respect CLI verbosity`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rpc-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("codex")
        try FakeExecutable.install(Self.stubScript, at: executable)
        let environment = [
            "CODEX_CLI_PATH": executable.path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]

        let quietStderr = try await Self.runCLI(environment: environment)
        #expect(!quietStderr.contains("[codex notify] remoteControl/status/changed"))
        #expect(!quietStderr.contains("[codex stderr] stub child diagnostic"))

        let verboseStderr = try await Self.runCLI(arguments: ["--verbose"], environment: environment)
        #expect(verboseStderr.contains("[codex notify] remoteControl/status/changed"))
        #expect(verboseStderr.contains("[codex stderr] stub child diagnostic"))
    }

    private static func runCLI(
        arguments: [String] = [],
        environment: [String: String]) async throws -> String
    {
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["usage", "--provider", "codex", "--source", "cli", "--json"] + arguments,
            environment: ProcessInfo.processInfo.environment.merging(environment) { _, override in override },
            timeout: 15,
            maxOutputBytes: 1024 * 1024,
            label: "fixture Codex RPC logging")
        return result.stderr
    }

    private static let stubScript = """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialized"'*)
          ;;
        *'"method":"initialize"'*|*'"method": "initialize"'*)
          printf '%s\n' '{"method":"remoteControl/status/changed","params":{}}'
          printf '%s\n' 'stub child diagnostic' >&2
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method"'*account*rateLimits*read*)
          printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,'\
    '"windowDurationMins":300,"resetsAt":1766948068}}}}'
          ;;
        *'"method"'*account*read*)
          printf '%s\n' '{"id":3,"result":{"account":{"type":"chatgpt","email":"stub@example.com",'\
    '"planType":"pro"},"requiresOpenaiAuth":false}}'
          ;;
      esac
    done
    """
}
