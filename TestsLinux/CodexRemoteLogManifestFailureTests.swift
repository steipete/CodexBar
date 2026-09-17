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

struct CodexRemoteLogManifestFailureTests {
    enum Failure: CaseIterable, Sendable {
        case unreadableDirectory, unreadableFile, unsafeName, symbolicLink, oversized, changing, traversal,
             multipleBatches

        var status: Int32 {
            switch self {
            case .unreadableDirectory, .unreadableFile: 43
            case .unsafeName, .symbolicLink: 44
            case .oversized, .multipleBatches: 45
            case .changing, .traversal: 46
            }
        }

        var error: CodexRemoteLogError {
            switch self {
            case .unreadableDirectory, .unreadableFile: .inaccessibleRoot
            case .unsafeName, .symbolicLink: .unsafePath
            case .oversized, .multipleBatches: .budgetExceeded
            case .changing, .traversal: .unstableSource
            }
        }
    }

    @Test(arguments: Failure.allCases)
    func `generated manifest preserves nested failure status and publishes no partial mirror`(_ failure: Failure)
        async throws
    {
        let fixture = try Fixture(failure: failure)
        defer { fixture.clean() }
        let command = fixture.command(CodexRemoteLogManifest.command(home: fixture.source.path, limits: fixture.limits))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.binary)
        process.arguments = command.arguments
        process.environment = command.environment
        let pipe = Pipe()
        let capture = ProcessPipeCapture(pipe: pipe, maxBytes: 16384)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        capture.start()
        process.waitUntilExit()
        let output = capture.finishSynchronously(timeout: 1)
        #expect(process.terminationStatus == failure.status)
        #expect(output.range(of: Data("END\0".utf8)) == nil)
        if failure == .changing {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fixture.source.appendingPathComponent("sessions/nested/valid.jsonl").path)
            #expect(attributes[.size] as? Int == 4)
        }

        let mirror = CodexRemoteLogMirror(
            environment: [:], temporaryRoot: fixture.mirrorRoot, limits: fixture.limits)
        { request in
            guard request.kind == .manifest, let script = request.arguments.last else {
                Issue.record("a rejected manifest must never start a transfer")
                throw CodexRemoteLogError.transferFailed
            }
            return try await CodexRemoteLogMirrorProcess.run(fixture.command(script))
        }
        do {
            _ = try await mirror.withMirror(source: .init(host: "Synthetic", home: fixture.source.path)) { _ in
                Issue.record("a rejected manifest must never publish partial logs")
                return true
            }
            Issue.record("the generated manifest unexpectedly succeeded")
        } catch let error as CodexRemoteLogError {
            #expect(error == failure.error)
            #expect(error.localizedDescription == failure.error.localizedDescription)
            #expect(!error.localizedDescription.contains("PRIVATE_CANARY"))
            if failure.status != 46 { #expect(!error.localizedDescription.contains("Retry")) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.mirrorRoot.path).isEmpty)
    }

    @Test
    func `generated manifest still streams a complete valid tree without status records`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let script = CodexRemoteLogManifest.command(home: fixture.source.path, limits: fixture.limits)
        let output = try await CodexRemoteLogMirrorProcess.run(fixture.command(script))
        let manifest = try CodexRemoteLogManifest(output, limits: fixture.limits)
        #expect(manifest.files.count == 1)
        #expect(manifest.files["sessions/nested/valid.jsonl"]?.size == 3)
        #expect(manifest.roots["archived_sessions"] == "missing")
        #expect(!output.contains("PRIVATE_CANARY"))
    }

    private struct Fixture: Sendable {
        let root: URL
        let source: URL
        let tools: URL
        let mirrorRoot: URL
        let denied: URL?
        let requiresUnprivilegedReader: Bool
        let limits = CodexRemoteLogMirror.Limits(fileBytes: 64)

        init(failure: Failure? = nil) throws {
            // Foundation preserves the /var alias on macOS; the production script rejects symlink ancestors.
            guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { free(canonical) }
            self.root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
                .appendingPathComponent("CodexManifest-\(UUID().uuidString)")
            self.source = self.root.appendingPathComponent("source")
            self.tools = self.root.appendingPathComponent("tools")
            self.mirrorRoot = self.root.appendingPathComponent("mirror")
            let nested = self.source.appendingPathComponent("sessions/nested")
            for directory in [self.root, self.source, self.tools, nested] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            }
            let valid = nested.appendingPathComponent("valid.jsonl")
            try Self.write(Data("{}\n".utf8), to: valid)
            var denied: URL?
            switch failure {
            case .unreadableDirectory:
                denied = nested
            case .unreadableFile:
                denied = valid
            case .unsafeName:
                try Self.write(Data("{}\n".utf8), to: nested.appendingPathComponent("PRIVATE_CANARY;unsafe.jsonl"))
            case .symbolicLink:
                try FileManager.default.createSymbolicLink(
                    at: nested.appendingPathComponent("link.jsonl"), withDestinationURL: valid)
            case .oversized, .multipleBatches:
                try Self.write(Data(repeating: 10, count: 65), to: valid)
            case .changing, .traversal, nil:
                break
            }
            self.denied = denied
            self.requiresUnprivilegedReader = denied != nil
            if let denied {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
            }
            #if os(macOS)
            // Exercise the generated shell and real BSD find on macOS without requiring Homebrew.
            // Linux runs the same script against its native GNU stat and sha256sum below.
            try FakeExecutable.install("""
            [ "$1" = -c ] && [ "$3" = -- ] || exit 1
            exec /usr/bin/stat -f '%z|%m|%c|%d|%i' "$4"
            """, at: self.tools.appendingPathComponent("stat"))
            let hash = "/usr/bin/shasum -a 256 \"$@\""
            #else
            let hash = "/usr/bin/sha256sum \"$@\""
            #endif
            if failure == .changing {
                try FakeExecutable.install("""
                \(hash) || exit 1
                printf '\\n' >> "$2"
                """, at: self.tools.appendingPathComponent("sha256sum"))
            } else {
                #if os(macOS)
                try FakeExecutable.install("exec " + hash, at: self.tools.appendingPathComponent("sha256sum"))
                #endif
            }
            if failure == .traversal {
                try FakeExecutable.install(
                    "printf 'PRIVATE_CANARY\\n' >&2; exit 1",
                    at: self.tools
                        .appendingPathComponent("find"))
            } else if failure == .multipleBatches {
                // Deterministic separate -exec batches: preserve the first declared error and drain later errors.
                try FakeExecutable.install("""
                /bin/sh -c "$5" sh "$7" "$8" "$1/nested/valid.jsonl" || :
                /bin/sh -c "$5" sh "$7" "$8" "$1/PRIVATE_CANARY;unsafe.jsonl" || :
                printf 'PRIVATE_CANARY\\n' >&2
                exit 1
                """, at: self.tools.appendingPathComponent("find"))
            }
        }

        func command(_ script: String) -> CodexRemoteLogMirror.Command {
            var binary = "/bin/sh"
            var arguments = ["-c", script]
            #if os(Linux)
            // Container tests often run as root; real unreadable-entry checks need an unprivileged reader.
            if geteuid() == 0, self.requiresUnprivilegedReader {
                binary = "/usr/sbin/runuser"
                arguments = ["-u", "nobody", "--", "/bin/sh"] + arguments
            }
            #endif
            return .init(
                kind: .manifest,
                binary: binary,
                arguments: arguments,
                environment: ["PATH": self.tools.path + ":/usr/bin:/bin", "HOME": self.source.path],
                outputBytes: 16384)
        }

        func clean() {
            if let denied {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
            }
            try? FileManager.default.removeItem(at: self.root)
        }

        private static func write(_ data: Data, to url: URL) throws {
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }
}
