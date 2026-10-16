#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLISleepInhibitorTests {
    @Test
    func `passive captures release only caffeinate in their owned process group`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-sleep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let companion = directory.appendingPathComponent("caffeinate")
        try FileManager.default.createSymbolicLink(atPath: companion.path, withDestinationPath: "/bin/sleep")
        let script = directory.appendingPathComponent("synthetic-claude")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              /usr/bin/caffeinate -i -t 30 &
              inhibitor=$!
              '\(companion.path)' 30 &
              companion=$!
              /bin/sleep 0.1
              printf 'Probe ready: %s %s %s\\n' "$$" "$inhibitor" "$companion"
              ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // A real executable in a separate synthetic group proves the group boundary, without a live account.
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        outside.arguments = ["-i", "-t", "30"]
        try outside.run()
        defer {
            if outside.isRunning { outside.terminate() }
            outside.waitUntilExit()
        }
        let session = ClaudeCLISession(workingDirectory: directory)
        do {
            var previousGroup: pid_t?
            for _ in 0..<2 {
                let output = try await session.capture(
                    subcommand: "/status",
                    binary: script.path,
                    timeout: 8,
                    environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path],
                    stopOnSubstrings: ["Probe ready:"])
                let line = try #require(output.components(separatedBy: "\n").first { $0.contains("Probe ready: ") })
                let pids = line.split(separator: " ")
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                #expect(pids.count == 3)
                let group = try #require(pids.first)
                if let previousGroup { #expect(group == previousGroup) }
                previousGroup = group
                let inhibitor = try #require(pids.dropFirst().first)
                let companion = try #require(pids.last)
                #expect(getpgid(group) == group)
                #expect(getpgid(companion) == group)
                #expect(getpgid(outside.processIdentifier) != group)
                let deadline = Date().addingTimeInterval(1)
                while DarwinProcessEnumerator.executablePath(pid: inhibitor) == "/usr/bin/caffeinate",
                      Date() < deadline
                {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(DarwinProcessEnumerator.executablePath(pid: inhibitor) != "/usr/bin/caffeinate")
                #expect(kill(companion, 0) == 0)
                #expect(outside.isRunning)
            }
            await session.reset()
        } catch {
            await session.reset()
            throw error
        }
    }
}
#endif
