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

    /// Regression test for #474: a hung subprocess must be killed and throw `.timedOut`
    /// instead of blocking indefinitely.
    @Test
    func throwsTimedOutWhenProcessHangs() async throws {
        do {
            _ = try await SubprocessRunner.run(
                binary: "/bin/sleep",
                arguments: ["3"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 0.5,
                label: "hung-process-test")
            Issue.record("Expected SubprocessRunnerError.timedOut but no error was thrown")
        } catch let error as SubprocessRunnerError {
            guard case .timedOut(let label) = error else {
                Issue.record("Expected .timedOut, got \(error)")
                return
            }
            #expect(label == "hung-process-test")
        } catch {
            Issue.record("Expected SubprocessRunnerError.timedOut, got unexpected error: \(error)")
        }
    }
}
