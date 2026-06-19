import XCTest
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ProviderVersionDetectorTests: XCTestCase {
    func test_run_returnsFirstLineForSuccessfulCommand() {
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "printf 'gemini 1.2.3\\nextra\\n'"],
            timeout: 1.0)

        XCTAssertEqual(version, "gemini 1.2.3")
    }

    func test_run_returnsNilAfterTimeout() {
        let start = Date()
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "sleep 5"],
            timeout: 0.1)
        let duration = Date().timeIntervalSince(start)

        XCTAssertNil(version)
        XCTAssertLessThan(duration, 2.0)
    }

    func test_run_returnsOutputWhenDetachedChildKeepsPipeOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-version-drain-\(UUID().uuidString)", isDirectory: true)
        let childPIDFile = root.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(childPID, SIGKILL)
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_TEST_CHILD_PID_FILE"] = childPIDFile.path
        let script = """
        (trap '' HUP; sleep 5) &
        child=$!
        printf '%s' "$child" > "$CODEXBAR_TEST_CHILD_PID_FILE"
        printf 'grok 1.2.3\\n'
        """

        let start = Date()
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", script],
            timeout: 1.0,
            environment: environment)
        let duration = Date().timeIntervalSince(start)

        XCTAssertEqual(version, "grok 1.2.3")
        XCTAssertLessThan(duration, 2.0)
        let childPID = try XCTUnwrap(
            pid_t(String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(childPID, 0), 0, "Descendant should still hold the inherited pipe open")
    }
}
