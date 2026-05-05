import Foundation
import Testing
@testable import CodexBarCore

struct SubprocessRunnerTests {
    @Test
    func `reads large stdout without deadlock`() async throws {
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
    ///
    /// This test was previously deleted (commit 3961770) because `waitUntilExit()` blocked
    /// the cooperative thread pool, starving the timeout task. The fix moves blocking calls
    /// to `DispatchQueue.global()`, making this test reliable.
    @Test
    func `throws timed out when process hangs`() async throws {
        let start = Date()
        do {
            _ = try await SubprocessRunner.run(
                binary: "/bin/sleep",
                arguments: ["5"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 1,
                label: "hung-process-test")
            Issue.record("Expected SubprocessRunnerError.timedOut but no error was thrown")
        } catch let error as SubprocessRunnerError {
            guard case let .timedOut(label) = error else {
                Issue.record("Expected .timedOut, got \(error)")
                return
            }
            #expect(label == "hung-process-test")
        } catch {
            Issue.record("Expected SubprocessRunnerError.timedOut, got unexpected error: \(error)")
        }

        let elapsed = Date().timeIntervalSince(start)
        // Must complete in well under 5s (the sleep duration). Allow generous bound for CI.
        #expect(elapsed < 3, "Timeout should fire in ~1s, not wait for process to exit naturally")
    }

    /// Multiple concurrent hung subprocesses must all time out independently, proving that
    /// one blocked subprocess does not starve the timeout mechanism of others.
    /// This is the core scenario that caused the original permanent-refresh-stall bug.
    @Test
    func `concurrent hung processes all time out`() async {
        let start = Date()
        let count = 8

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    do {
                        _ = try await SubprocessRunner.run(
                            binary: "/bin/sleep",
                            arguments: ["5"],
                            environment: ProcessInfo.processInfo.environment,
                            timeout: 2,
                            label: "concurrent-hung-\(i)")
                        Issue.record("Expected .timedOut for concurrent-hung-\(i)")
                    } catch let error as SubprocessRunnerError {
                        guard case .timedOut = error else {
                            Issue.record("Expected .timedOut for concurrent-hung-\(i), got \(error)")
                            return
                        }
                    } catch {
                        Issue.record("Unexpected error for concurrent-hung-\(i): \(error)")
                    }
                }
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        // All 8 should time out in ~2s (parallel), not wait for the 5s sleep.
        // Use a generous 4s bound for slow CI.
        #expect(
            elapsed < 4,
            "All \(count) concurrent timeouts should fire in ~2s, took \(elapsed)s")
    }

    /// Stress-test the timeout race guard: with very short timeouts, the exit-code task
    /// and the timeout task race tightly, exercising the KillFlag synchronization path.
    @Test
    func `timeout race stress`() async {
        for i in 0..<20 {
            do {
                _ = try await SubprocessRunner.run(
                    binary: "/bin/sleep",
                    arguments: ["1"],
                    environment: ProcessInfo.processInfo.environment,
                    timeout: 0.1,
                    label: "race-stress-\(i)")
                Issue.record("Expected .timedOut for iteration \(i)")
            } catch let error as SubprocessRunnerError {
                guard case .timedOut = error else {
                    Issue.record("Expected .timedOut, got \(error) at iteration \(i)")
                    continue
                }
            } catch {
                Issue.record("Unexpected error at iteration \(i): \(error)")
            }
        }
    }

    /// Verify that many concurrent SubprocessRunner calls complete without starving each other.
    @Test
    func `concurrent calls do not starve`() async throws {
        try await withThrowingTaskGroup(of: SubprocessResult.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await SubprocessRunner.run(
                        binary: "/bin/sleep",
                        arguments: ["0.2"],
                        environment: ProcessInfo.processInfo.environment,
                        timeout: 10,
                        label: "concurrent-\(i)")
                }
            }

            var count = 0
            for try await _ in group {
                count += 1
            }
            #expect(count == 20, "All 20 concurrent calls should complete")
        }
    }
}
