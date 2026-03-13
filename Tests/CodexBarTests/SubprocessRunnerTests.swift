import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct SubprocessRunnerTests {
    @Test
    func readsLargeStdoutWithoutDeadlock() async throws {
        let result = try await SubprocessRunner.run(
            binary: "/usr/bin/python3",
            arguments: ["-c", "print('x' * 1_000_000)"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5,
            label: "python large stdout")

        #expect(result.stdout.count >= 1_000_000)
        #expect(result.stderr.isEmpty)
    }
}
