import Foundation
import Testing

@Suite(.serialized)
struct CodexRPCLoggingTests {
    @Test
    func `Codex RPC diagnostics respect CLI verbosity`() throws {
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

        let quiet = try Self.runCLI(environment: environment)
        #expect(quiet.status == 0)
        let quietStderr = try #require(String(bytes: quiet.stderr, encoding: .utf8))
        #expect(!quietStderr.contains("[codex notify] remoteControl/status/changed"))
        #expect(!quietStderr.contains("[codex stderr] stub child diagnostic"))

        let verbose = try Self.runCLI(arguments: ["--verbose"], environment: environment)
        #expect(verbose.status == 0)
        let verboseStderr = try #require(String(bytes: verbose.stderr, encoding: .utf8))
        #expect(verboseStderr.contains("[codex notify] remoteControl/status/changed"))
        #expect(verboseStderr.contains("[codex stderr] stub child diagnostic"))
    }

    private static func runCLI(
        arguments: [String] = [],
        environment: [String: String]) throws -> (status: Int32, stderr: Data)
    {
        let process = Process()
        process.executableURL = TestBuildProducts.executableURL(named: "CodexBarCLI")
        process.arguments = ["usage", "--provider", "codex", "--source", "cli", "--json"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }

        process.standardOutput = Pipe()
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, stderr.fileHandleForReading.readDataToEndOfFile())
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
