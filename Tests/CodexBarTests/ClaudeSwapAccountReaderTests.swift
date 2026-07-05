import Foundation
import Testing
@testable import CodexBarCore

/// Reader tests use fake executables only, per the Phase 1 contract: no real
/// claude-swap install, no credentials, no Keychain access.
struct ClaudeSwapAccountReaderTests {
    private func makeFakeExecutable(_ script: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cswap")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test
    func `reads and parses a schema v1 list from the executable`() async throws {
        let path = try self.makeFakeExecutable("""
        [ "$1" = "--list" ] || exit 2
        [ "$2" = "--json" ] || exit 2
        cat <<'EOF'
        {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
          {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "ok",
           "usage": {"fiveHour": {"pct": 12.5}}}
        ]}
        EOF
        """)

        let list = try await ClaudeSwapAccountReader.readAccountList(executablePath: path)
        #expect(list.activeAccountNumber == 1)
        #expect(list.accounts.first?.fiveHour?.usedPercent == 12.5)
    }

    @Test
    func `surfaces the error envelope from a non zero exit`() async throws {
        let path = try self.makeFakeExecutable("""
        echo '{"schemaVersion": 1, "error": {"type": "SwitchError", "message": "store locked"}}'
        exit 1
        """)

        await #expect(throws: ClaudeSwapListParserError.reportedError(type: "SwitchError", message: "store locked")) {
            try await ClaudeSwapAccountReader.readAccountList(executablePath: path)
        }
    }

    @Test
    func `terminates executables that exceed the timeout`() async throws {
        let path = try self.makeFakeExecutable("sleep 30")

        await #expect(throws: (any Error).self) {
            try await ClaudeSwapAccountReader.readAccountList(executablePath: path, timeout: 0.5)
        }
    }

    @Test
    func `rejects oversized output before parsing`() async throws {
        let path = try self.makeFakeExecutable("""
        i=0
        while [ $i -lt 5000 ]; do
          printf '%s' '{"filler": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}'
          i=$((i+1))
        done
        """)

        await #expect(throws: (any Error).self) {
            try await ClaudeSwapAccountReader.readAccountList(executablePath: path)
        }
    }

    @Test
    func `fails cleanly when the executable is missing`() async throws {
        await #expect(throws: (any Error).self) {
            try await ClaudeSwapAccountReader.readAccountList(
                executablePath: "/nonexistent/path/to/cswap")
        }
        await #expect(throws: ClaudeSwapAccountReaderError.self) {
            try await ClaudeSwapAccountReader.readAccountList(executablePath: "   ")
        }
    }

    @Test
    func `reads the executable version`() async throws {
        let path = try self.makeFakeExecutable("""
        [ "$1" = "--version" ] || exit 2
        echo 'cswap 0.16.0'
        """)

        let version = await ClaudeSwapAccountReader.readVersion(executablePath: path)
        #expect(version == "0.16.0")
    }

    @Test
    func `version probe returns nil when the executable fails`() async throws {
        let path = try self.makeFakeExecutable("exit 3")

        let version = await ClaudeSwapAccountReader.readVersion(executablePath: path)
        #expect(version == nil)
    }

    @Test
    func `cancellation during version probe prevents account list launch`() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-list-launched-\(UUID().uuidString)")
        let path = try self.makeFakeExecutable("""
        if [ "$1" = "--version" ]; then
          sleep 30
          exit 0
        fi
        touch '\(marker.path)'
        echo '{"schemaVersion":1,"activeAccountNumber":null,"accounts":[]}'
        """)
        let task = Task {
            _ = await ClaudeSwapAccountReader.readVersion(executablePath: path)
            return try await ClaudeSwapAccountReader.readAccountList(executablePath: path)
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func `expands tilde in configured paths`() throws {
        let resolved = try ClaudeSwapAccountReader.resolvedExecutablePath("~/bin/cswap")
        #expect(resolved.hasPrefix("/"))
        #expect(!resolved.contains("~"))
        #expect(resolved.hasSuffix("/bin/cswap"))
    }
}
