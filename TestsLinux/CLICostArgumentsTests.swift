import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

#if os(Linux)
struct CLICostArgumentsTests {
    @Test(arguments: [("0", 1), ("1", 1), ("7", 7), ("365", 365), ("999", 365)])
    func `integer days retain rolling precedence and clamping`(value: (String, Int)) throws {
        let parser = CommandParser(signature: CodexBarCLI._costSignatureForTesting())
        let values = try parser.parse(arguments: ["--days", value.0, "--period", "month-to-date"])
        #expect(CodexBarCLI.decodeCostReportingPeriod(from: values, saved: .allTime) == .rolling(days: value.1))
    }

    @Test(arguments: ["banana", "1.5", "99999999999999999999999999999"])
    func `malformed days fail instead of falling back to a reporting period`(days: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-arguments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("CodexBarCLI")
        for periodArguments in [[], ["--period", "month-to-date"]] {
            do {
                _ = try await SubprocessRunner.run(
                    binary: binary.path,
                    arguments: ["cost", "--provider", "codex", "--provider-native-only", "--days", days]
                        + periodArguments,
                    environment: [
                        "PATH": "/usr/bin:/bin",
                        "HOME": directory.path,
                        "CODEX_HOME": directory.appendingPathComponent("codex").path,
                        "CODEXBAR_CONFIG": directory.appendingPathComponent("config.json").path,
                        "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1",
                    ],
                    timeout: 15,
                    label: "invalid-cost-days")
                Issue.record("Malformed --days must fail instead of returning a cost report")
            } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
                #expect(code == 1)
                #expect(stderr.contains("--days must be an integer"))
            }
        }
    }
}
#endif
