#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexRemoteLogGuardianTests {
    private static let callerKey = "CODEXBAR_TEST_GUARDIAN_CALLER"
    static var builtCLIPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CodexBarCLI").path
    }

    private struct Fixture: Sendable {
        let root: URL
        let receiver: URL
        let writer: URL
        let requests: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.receiver = self.root.appendingPathComponent("receiver.sh")
            self.writer = self.root.appendingPathComponent("writer.sh")
            self.requests = self.root.appendingPathComponent("requests")
            try CodexRemoteLogStorage.privateDirectory(self.root)
            let script = """
            #!/bin/sh
            umask 077
            /bin/sh "$CODEXBAR_TEST_WRITER" "$CODEXBAR_TEST_DIRECTORY" &
            child=$!
            while [ ! -f "$CODEXBAR_TEST_DIRECTORY/started" ]; do /bin/sleep 0.01; done
            if [ "$CODEXBAR_TEST_RECEIVER_MODE" = exit ]; then exit 0; fi
            wait "$child"
            """
            try Self.executable(script, at: self.receiver)
            let chunk = String(repeating: "x", count: 1024)
            try Self.executable("""
            #!/bin/sh
            umask 077
            trap '' TERM HUP INT
            printf '%s' "$$" > "$1/started"
            while :; do printf '\(chunk)' >> "$1/synthetic.raw"; /bin/sleep 0.02; done
            """, at: self.writer)
        }

        static func executable(_ script: String, at url: URL) throws {
            try CodexRemoteLogStorage.privateFile(Data(script.utf8), at: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        func command(
            request: CodexRemoteLogStorage.Request,
            seconds: Int,
            mode: String = "wait",
            fileBytes: Int64 = 262_144)
            throws -> CodexRemoteLogMirror.Command
        {
            let staging = request.url.appendingPathComponent("staging")
            try CodexRemoteLogStorage.privateDirectory(staging)
            return try Self.command(
                root: self.root,
                request: request,
                seconds: seconds,
                mode: mode,
                fileBytes: fileBytes)
        }

        static func command(
            root: URL,
            request: CodexRemoteLogStorage.Request,
            seconds: Int,
            mode: String,
            fileBytes: Int64)
            throws -> CodexRemoteLogMirror.Command
        {
            let staging = request.url.appendingPathComponent("staging")
            var environment: [String: String] = [
                "CODEXBAR_SSH_GUARDIAN_PATH": CodexRemoteLogGuardianTests.builtCLIPath,
                "CODEXBAR_SSH_GUARDIAN_RECEIVER": root.appendingPathComponent("receiver.sh").path,
                "CODEXBAR_TEST_WRITER": root.appendingPathComponent("writer.sh").path,
                "CODEXBAR_TEST_DIRECTORY": staging.path,
                "CODEXBAR_TEST_RECEIVER_MODE": mode,
            ]
            environment["PATH"] = "/usr/bin:/bin"
            var limits = CodexRemoteLogMirror.Limits()
            limits.fileBytes = fileBytes
            let mirror = CodexRemoteLogMirror(environment: environment, temporaryRoot: nil, limits: limits)
            var command = mirror.transferCommand(
                source: .init(host: "synthetic"), home: "/synthetic/codex",
                list: root.appendingPathComponent("unused"), staging: staging, remainingSeconds: seconds)
            command.lockDescriptor = request.descriptor
            return command
        }

        func clean() { try? FileManager.default.removeItem(at: self.root) }
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(predicate())
    }

    private static func writerIdentity(_ directory: URL) throws -> TTYProcessTreeTerminator.ProcessIdentity {
        let string = try String(contentsOf: directory.appendingPathComponent("started"), encoding: .utf8)
        let pid = try #require(Int32(string))
        return try #require(TTYProcessTreeTerminator.processIdentity(for: pid))
    }

    private static func stopFixtureWriter(_ identity: TTYProcessTreeTerminator.ProcessIdentity) {
        if TTYProcessTreeTerminator.isCurrent(identity) { _ = kill(identity.pid, SIGKILL) }
    }

    private static func assertDrained(
        _ identity: TTYProcessTreeTerminator.ProcessIdentity,
        directory: URL) async throws
    {
        #expect(!TTYProcessTreeTerminator.isLive(identity))
        let file = directory.appendingPathComponent("synthetic.raw")
        let before = (try? CodexRemoteLogStorage.attributes(file).st_size) ?? 0
        try await Task.sleep(for: .milliseconds(150))
        #expect(((try? CodexRemoteLogStorage.attributes(file).st_size) ?? 0) == before)
    }

    @Test func `guardian caller subprocess fixture`() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.callerKey] else { return }
        let root = URL(fileURLWithPath: path)
        let request = try CodexRemoteLogStorage.create(root: root.appendingPathComponent("requests"))
        try CodexRemoteLogStorage.privateDirectory(request.url.appendingPathComponent("staging"))
        try CodexRemoteLogStorage.privateFile(
            Data(request.url.path.utf8),
            at: root.appendingPathComponent("request-path"))
        let command = try Fixture.command(root: root, request: request, seconds: 3, mode: "wait", fileBytes: 262_144)
        _ = try await CodexRemoteLogMirrorProcess.run(command)
        withExtendedLifetime(request) {}
    }

    @Test func `SIGKILL of actual caller retains lock until descendant writer stops`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let caller = Process()
        caller.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        caller.arguments = [
            "--filter",
            "CodexRemoteLogGuardianTests/`guardian caller subprocess fixture`",
            "--testing-library",
            "swift-testing",
        ]
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
           CommandLine.arguments.indices.contains(index + 1)
        {
            caller.arguments = ["--test-bundle-path", CommandLine.arguments[index + 1]] + (caller.arguments ?? [])
        }
        var environment = ProcessInfo.processInfo.environment
        environment[Self.callerKey] = fixture.root.path
        caller.environment = environment
        caller.standardOutput = FileHandle.nullDevice
        caller.standardError = FileHandle.nullDevice
        try caller.run()
        let pathFile = fixture.root.appendingPathComponent("request-path")
        try await Self.waitUntil { FileManager.default.fileExists(atPath: pathFile.path) || !caller.isRunning }
        let requestURL = try URL(fileURLWithPath: String(contentsOf: pathFile, encoding: .utf8))
        let staging = requestURL.appendingPathComponent("staging")
        try await Self
            .waitUntil { FileManager.default.fileExists(atPath: staging.appendingPathComponent("started").path) }
        let identity = try Self.writerIdentity(staging)
        defer { Self.stopFixtureWriter(identity) }
        _ = kill(caller.processIdentifier, SIGKILL)
        caller.waitUntilExit()
        #expect(CodexRemoteLogStorage.abandoned(requestURL) == nil)
        let deadline = Date().addingTimeInterval(7)
        while TTYProcessTreeTerminator.isLive(identity), Date() < deadline {
            #expect(CodexRemoteLogStorage.abandoned(requestURL) == nil)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Self.waitUntil { CodexRemoteLogStorage.abandoned(requestURL) != nil }
        try await Self.assertDrained(identity, directory: staging)
        try await CodexRemoteLogMirror(environment: [:], temporaryRoot: fixture.requests).cleanupAbandonedRequests()
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))
    }

    @Test(arguments: ["cancel", "deadline", "exit"])
    func `cancel deadline and receiver exit drain descendants before unlocking`(_ mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var request: CodexRemoteLogStorage.Request? = try CodexRemoteLogStorage.create(root: fixture.requests)
        let requestURL = try #require(request).url
        let staging = requestURL.appendingPathComponent("staging")
        let command = try fixture.command(request: #require(request), seconds: mode == "deadline" ? 1 : 10, mode: mode)
        let task = Task { try await CodexRemoteLogMirrorProcess.run(command) }
        try await Self
            .waitUntil { FileManager.default.fileExists(atPath: staging.appendingPathComponent("started").path) }
        let identity = try Self.writerIdentity(staging)
        defer { Self.stopFixtureWriter(identity) }
        request = nil
        if mode != "exit" { #expect(CodexRemoteLogStorage.abandoned(requestURL) == nil) }
        if mode == "cancel" {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else if mode == "deadline" {
            await #expect(throws: CodexRemoteLogError.timedOut) { try await task.value }
        } else {
            _ = try await task.value
        }
        try await Self.assertDrained(identity, directory: staging)
        #expect(CodexRemoteLogStorage.abandoned(requestURL) != nil)
        try await CodexRemoteLogMirror(environment: [:], temporaryRoot: fixture.requests).cleanupAbandonedRequests()
    }

    @Test func `guardian applies the kernel file limit to its receiver`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.receiver)
        try Fixture.executable("""
        #!/bin/sh
        exec /bin/dd if=/dev/zero of="$CODEXBAR_TEST_DIRECTORY/limited.raw" bs=1024 count=64
        """, at: fixture.receiver)
        let request = try CodexRemoteLogStorage.create(root: fixture.requests)
        let command = try fixture.command(request: request, seconds: 5, fileBytes: 8192)
        await #expect(throws: CodexRemoteLogError.transferFailed) { try await CodexRemoteLogMirrorProcess.run(command) }
        let size = try CodexRemoteLogStorage.attributes(request.url.appendingPathComponent("staging/limited.raw"))
            .st_size
        #expect(size > 0 && size <= 8192)
        try CodexRemoteLogStorage.removeRequest(request.url)
        withExtendedLifetime(request) {}
    }
}
