import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CodexRemoteLogMirrorTests {
    private actor Counter {
        var value = 0
        func next() -> Int {
            self.value += 1
            return self.value
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let source: URL
        let temporary: URL
        let bytes = Data("{\"record\":1}\n".utf8)

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.source = self.root.appendingPathComponent("source")
            self.temporary = self.root.appendingPathComponent("mirror")
            try CodexRemoteLogStorage.privateDirectory(self.root)
            try CodexRemoteLogStorage.privateDirectory(self.source)
            try CodexRemoteLogStorage.privateDirectory(self.source.appendingPathComponent("sessions"))
            try CodexRemoteLogStorage.privateFile(
                self.bytes,
                at: self.source.appendingPathComponent("sessions/a.jsonl"))
            try CodexRemoteLogStorage.privateFile(
                Data("never copy".utf8),
                at: self.source.appendingPathComponent("auth.json"))
        }

        func clean() { try? FileManager.default.removeItem(at: self.root) }

        var manifest: String {
            [
                "CODEX_LOGS_V1",
                "/synthetic/codex",
                "R",
                "sessions",
                "present",
                "D",
                "sessions",
                "F",
                "sessions/a.jsonl",
                String(self.bytes.count),
                "stable-revision",
                CodexRemoteLogManifest.digest(self.bytes),
                "R",
                "archived_sessions",
                "missing",
                "END",
                "",
            ]
                .joined(separator: "\0")
        }

        func runner(_ command: CodexRemoteLogMirror.Command) async throws -> String {
            if command.kind == .manifest { return self.manifest }
            var arguments = command.arguments
            arguments[arguments.count - 2] = self.source.path + "/"
            return try await CodexRemoteLogMirrorProcess.run(.init(
                kind: .transfer, binary: CodexRemoteLogGuardianTests.builtCLIPath, arguments: arguments,
                environment: command.environment, outputBytes: command.outputBytes,
                lockDescriptor: command.lockDescriptor))
        }

        func mirror(limits: CodexRemoteLogMirror.Limits = .init()) -> CodexRemoteLogMirror {
            CodexRemoteLogMirror(environment: [:], temporaryRoot: self.temporary, limits: limits, runner: self.runner)
        }

        func expectClean() throws {
            #expect(try FileManager.default.contentsOfDirectory(atPath: self.temporary.path).isEmpty)
        }
    }

    @Test func `source validation preserves case and rejects shell or option input`() throws {
        let source = CodexRemoteLogSource(host: "User@Research-Host", home: "~/codex.logs")
        try source.validate()
        #expect(source.host == "User@Research-Host")
        for host in [
            "-Fconfig",
            ".",
            "..",
            ".host",
            ".user@host",
            "host\nother",
            "host;id",
            "host x",
            "a:b",
            "a@@b",
            "host$(id)",
        ] {
            #expect(throws: CodexRemoteLogError.invalidSource) { try CodexRemoteLogSource(host: host).validate() }
        }
        for home in ["relative", "/tmp/../secret", "/tmp//codex", "~user/.codex", "~/a b", "~/$(id)", "/tmp/`id`"] {
            #expect(throws: CodexRemoteLogError.invalidSource) {
                try CodexRemoteLogSource(host: "fixture", home: home).validate()
            }
        }
    }

    @Test func `actual system rsync copies only allowed files with private permissions and awaits cleanup`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let result = try await fixture.mirror().withMirror(source: .init(host: "Fixture")) { snapshot in
            #expect(snapshot.roots.count == 2)
            #expect(snapshot.roots.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "ready" })
            #expect(snapshot.capturedTo >= snapshot.capturedFrom)
            let files = try CodexRemoteLogStorage.verifyTree(
                snapshot.roots[0].deletingLastPathComponent(),
                limits: .init())
            #expect(files == ["sessions/a.jsonl": Int64(fixture.bytes.count)])
            #expect(try Data(contentsOf: snapshot.roots[0].appendingPathComponent("a.jsonl")) == fixture.bytes)
            try CodexRemoteLogStorage.privateFile(
                Data("temporary db".utf8),
                at: snapshot.scanCacheRoot.appendingPathComponent("cost.db-wal"))
            return 17
        }
        #expect(result == 17)
        try fixture.expectClean()
        #expect(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("auth.json").path))
    }

    @Test func `consumer failure still deletes raw logs and scan sidecars`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await #expect(throws: CodexRemoteLogError.unstableSource) {
            try await fixture.mirror().withMirror(source: .init(host: "Fixture")) { snapshot -> Int in
                try CodexRemoteLogStorage.privateFile(
                    Data("raw".utf8),
                    at: snapshot.scanCacheRoot.appendingPathComponent("cost.db"))
                throw CodexRemoteLogError.unstableSource
            }
        }
        try fixture.expectClean()
    }

    @Test func `manifest rejects traversal collision missing entries unreadable roots and budgets`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let valid = fixture.manifest
        #expect(try CodexRemoteLogManifest(valid, limits: .init()).roots["archived_sessions"] == "missing")
        #expect(throws: CodexRemoteLogError.inaccessibleRoot) {
            try CodexRemoteLogManifest(
                valid.replacingOccurrences(of: "missing\0", with: "unreadable\0"),
                limits: .init())
        }
        for path in ["sessions/../a.jsonl", "/sessions/a.jsonl", "sessions/a;id.jsonl", "sessions/a\nb.jsonl"] {
            #expect(throws: CodexRemoteLogError.unsafePath) {
                try CodexRemoteLogManifest(
                    valid.replacingOccurrences(of: "sessions/a.jsonl", with: path),
                    limits: .init())
            }
        }
        let collision = "F\0sessions/A.jsonl\0\(fixture.bytes.count)\0revision\0\(CodexRemoteLogManifest.digest(fixture.bytes))\0END\0"
        #expect(throws: CodexRemoteLogError.unsafePath) {
            try CodexRemoteLogManifest(valid.replacingOccurrences(of: "END\0", with: collision), limits: .init())
        }
        #expect(throws: CodexRemoteLogError.invalidManifest) {
            try CodexRemoteLogManifest(valid.replacingOccurrences(of: "END\0", with: ""), limits: .init())
        }
        var limits = CodexRemoteLogMirror.Limits()
        limits.totalBytes = 1
        #expect(throws: CodexRemoteLogError.budgetExceeded) { try CodexRemoteLogManifest(valid, limits: limits) }
        limits = .init()
        limits.fileBytes = 1
        #expect(throws: CodexRemoteLogError.budgetExceeded) { try CodexRemoteLogManifest(valid, limits: limits) }
        limits = .init()
        limits.fileCount = 0
        #expect(throws: CodexRemoteLogError.budgetExceeded) { try CodexRemoteLogManifest(valid, limits: limits) }
    }

    @Test func `omitted or modified transfer cannot publish`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let omitted = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: .init())
        { command in
            command.kind == .manifest ? fixture.manifest : ""
        }
        await #expect(throws: CodexRemoteLogError.transferFailed) {
            try await omitted.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        try fixture.expectClean()
        let modified = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: .init())
        { command in
            if command.kind == .manifest { return fixture.manifest }
            try Data("{\"record\":2}\n".utf8).write(to: fixture.source.appendingPathComponent("sessions/a.jsonl"))
            return try await fixture.runner(command)
        }
        await #expect(throws: CodexRemoteLogError.unstableSource) {
            try await modified.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        try fixture.expectClean()
    }

    @Test func `post-transfer changed manifest and vanished source fail closed`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let counter = Counter()
        let changed = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: .init())
        { command in
            if command.kind == .manifest {
                return await counter.next() == 1 ? fixture.manifest
                    : fixture.manifest.replacingOccurrences(of: "stable-revision", with: "modified-revision")
            }
            return try await fixture.runner(command)
        }
        await #expect(throws: CodexRemoteLogError.unstableSource) {
            try await changed.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        try fixture.expectClean()
        let vanished = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: .init())
        { command in
            if command.kind == .manifest { return fixture.manifest }
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("sessions/a.jsonl"))
            return try await fixture.runner(command)
        }
        await #expect(throws: CodexRemoteLogError.transferFailed) {
            try await vanished.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        try fixture.expectClean()
    }

    @Test func `partial transfer cannot publish and deletes all staged files`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let mirror = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: .init())
        { command in
            if command.kind == .manifest { return fixture.manifest }
            let staging = try URL(fileURLWithPath: #require(command.arguments.last))
            let target = staging.appendingPathComponent("sessions/a.jsonl")
            try CodexRemoteLogStorage.privateFile(fixture.bytes.prefix(3), at: target)
            #expect(try CodexRemoteLogStorage.attributes(target).st_mode & 0o777 == 0o600)
            return ""
        }
        await #expect(throws: CodexRemoteLogError.transferFailed) {
            try await mirror.withMirror(source: .init(host: "Fixture")) { _ in
                Issue.record("An incomplete staging tree reached the consumer")
            }
        }
        try fixture.expectClean()
    }

    @Test func `unterminated last JSONL record is rejected`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let url = fixture.source.appendingPathComponent("sessions/a.jsonl")
        try Data("{\"record\":1}".utf8).write(to: url)
        #expect(throws: CodexRemoteLogError.unstableSource) { try CodexRemoteLogManifest.fileDigest(url) }
    }

    @Test func `disk watchdog stops actual file growth during transfer`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var limits = CodexRemoteLogMirror.Limits()
        limits.totalBytes = 12 * 1024
        limits.fileBytes = 16 * 1024
        let mirror = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: limits)
        { command in
            if command.kind == .manifest { return fixture.manifest }
            let destination = try URL(fileURLWithPath: #require(command.arguments.last))
                .appendingPathComponent("growing.jsonl")
            let started = Date()
            do {
                return try await CodexRemoteLogMirrorProcess.run(.init(
                    kind: .transfer, binary: "/bin/sh",
                    arguments: [
                        "-c",
                        "umask 077; while :; do dd if=/dev/zero bs=1024 count=1 >>\"$1\" 2>/dev/null; sleep 0.01; done",
                        "fixture",
                        destination.path,
                    ],
                    environment: [:], outputBytes: 1024))
            } catch {
                let size = try CodexRemoteLogStorage.attributes(destination).st_size
                print(
                    "Mirror cutoff fixture: threshold=12288 actual=\(size) overshoot=\(size - 12288) elapsed=\(Date().timeIntervalSince(started))s")
                throw error
            }
        }
        let started = Date()
        await #expect(throws: CodexRemoteLogError.budgetExceeded) {
            try await mirror.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        #expect(Date().timeIntervalSince(started) < 3)
        try fixture.expectClean()
    }

    @Test func `timeout cancellation and nonzero process failures drain before cleanup`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var limits = CodexRemoteLogMirror.Limits()
        limits.seconds = 0.15
        let runner: CodexRemoteLogMirror.Runner = { command in
            if command.kind == .manifest { return fixture.manifest }
            return try await CodexRemoteLogMirrorProcess.run(.init(
                kind: .transfer, binary: "/bin/sh", arguments: ["-c", "sleep 10"], environment: [:], outputBytes: 1024))
        }
        let short = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: limits,
            runner: runner)
        await #expect(throws: CodexRemoteLogError.timedOut) {
            try await short.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        try fixture.expectClean()
        let normal = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: .init(),
            runner: runner)
        let task = Task { try await normal.withMirror(source: .init(host: "Fixture")) { _ in true } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CodexRemoteLogError.cancelled) { try await task.value }
        try fixture.expectClean()
        let failure = CodexRemoteLogMirror(
            environment: [:],
            temporaryRoot: fixture.temporary,
            limits: .init())
        { command in
            if command.kind == .manifest { return fixture.manifest }
            return try await CodexRemoteLogMirrorProcess.run(.init(
                kind: .transfer, binary: "/bin/sh", arguments: ["-c", "echo PRIVATE_CONTENT >&2; exit 23"],
                environment: [:], outputBytes: 1024))
        }
        await #expect(throws: CodexRemoteLogError.transferFailed) {
            try await failure.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        #expect(!CodexRemoteLogError.transferFailed.localizedDescription.contains("PRIVATE_CONTENT"))
        try fixture.expectClean()
    }

    @Test func `cleanup failure is visible and owned inactive requests can be retried`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let mirror = CodexRemoteLogMirror(
            environment: [:], temporaryRoot: fixture.temporary, limits: .init(), runner: fixture.runner,
            remove: { _ in throw CodexRemoteLogError.localStorage })
        await #expect(throws: CodexRemoteLogError.cleanupFailed) {
            try await mirror.withMirror(source: .init(host: "Fixture")) { _ in true }
        }
        #expect(CodexRemoteLogError.cleanupFailed.isCleanupFailure)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).count == 1)
        try await fixture.mirror().cleanupAbandonedRequests()
        try fixture.expectClean()
    }

    @Test func `orphan cleanup respects active locks exact markers and symlink boundaries`() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let active = try CodexRemoteLogStorage.create(root: fixture.temporary)
        let unowned = fixture.temporary.appendingPathComponent("request-" + UUID().uuidString)
        try CodexRemoteLogStorage.privateDirectory(unowned)
        let outside = fixture.root.appendingPathComponent("outside")
        try CodexRemoteLogStorage.privateDirectory(outside)
        let symlink = fixture.temporary.appendingPathComponent("request-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try await fixture.mirror().cleanupAbandonedRequests()
        #expect(FileManager.default.fileExists(atPath: active.url.path))
        #expect(FileManager.default.fileExists(atPath: unowned.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        withExtendedLifetime(active) {}
    }

    @Test func `received symlink and special file are rejected`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("sessions/link.jsonl"),
            withDestinationURL: fixture.source
                .appendingPathComponent("auth.json"))
        #expect(throws: CodexRemoteLogError.unsafePath) {
            try CodexRemoteLogStorage.verifyTree(fixture.source.appendingPathComponent("sessions"), limits: .init())
        }
    }

    @Test func `SSH arguments are strict and rsync retains bidirectional stdin`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let command = fixture.mirror().transferCommand(
            source: .init(host: "MixedCase"),
            home: "/synthetic/codex",
            list: fixture.root.appendingPathComponent("files"),
            staging: fixture.temporary)
        let index = try #require(command.arguments.firstIndex(of: "-e"))
        let shell = command.arguments[index + 1]
        #expect(!shell.split(separator: " ").contains("-n"))
        #expect(shell.contains("-oStrictHostKeyChecking=yes"))
        #expect(shell.contains("-oBatchMode=yes"))
        #expect(command.arguments.contains("MixedCase:/synthetic/codex/"))
        #expect(command.arguments.contains("-0"))
    }

    @Test func `local fingerprint changes for primary config and ordinary includes without SSH`() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ssh = fixture.root.appendingPathComponent(".ssh")
        try CodexRemoteLogStorage.privateDirectory(ssh)
        let config = ssh.appendingPathComponent("config")
        let included = ssh.appendingPathComponent("extra.conf")
        try Data("Include *.conf\nHost fixture\n  HostName one\n".utf8).write(to: config)
        try Data("Host fixture\n Port 2200\n".utf8).write(to: included)
        let environment = ["HOME": fixture.root.path]
        let first = CodexRemoteLogMirror.configurationFingerprint(environment: environment)
        try Data("Host fixture\n Port 2201\n".utf8).write(to: included)
        let second = CodexRemoteLogMirror.configurationFingerprint(environment: environment)
        #expect(first != second)
        try Data("Include *.conf\nHost fixture\n  HostName two\n".utf8).write(to: config)
        #expect(second != CodexRemoteLogMirror.configurationFingerprint(environment: environment))
        #if DEBUG
        let explicit = fixture.root.appendingPathComponent("proof-config")
        try Data("Host proof\n HostName one\n".utf8).write(to: explicit)
        let proofEnvironment = ["HOME": fixture.root.path, "CODEXBAR_SSH_CONFIG_FILE": explicit.path]
        let proofFirst = CodexRemoteLogMirror.configurationFingerprint(environment: proofEnvironment)
        try Data("Host proof\n HostName two\n".utf8).write(to: explicit)
        #expect(proofFirst != CodexRemoteLogMirror.configurationFingerprint(environment: proofEnvironment))
        #endif
    }
}
