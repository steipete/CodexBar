import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CodexRemoteLogPermissionsTests {
    private actor Observations {
        var fileModes: Set<Int> = []
        var directoryModes: Set<Int> = []
        var temporaryFiles: Set<String> = []
        var filesObservedDuringWrite: Set<String> = []
        var maximumFileCount = 0

        func sample(_ root: URL) {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else { return }
            var fileCount = 0
            for case let url as URL in entries {
                // A completed rsync temporary file can disappear between enumeration and lstat.
                guard let attributes = try? CodexRemoteLogStorage.attributes(url) else { continue }
                let mode = Int(attributes.st_mode & 0o777)
                if CodexRemoteLogStorage.isDirectory(attributes) {
                    self.directoryModes.insert(mode)
                } else {
                    fileCount += 1
                    self.fileModes.insert(mode)
                    if attributes.st_size > 0 { self.filesObservedDuringWrite.insert(url.lastPathComponent) }
                    if url.lastPathComponent.hasPrefix("."), attributes.st_size > 0 {
                        self.temporaryFiles.insert(url.lastPathComponent)
                    }
                }
            }
            self.maximumFileCount = max(self.maximumFileCount, fileCount)
        }

        func verify() {
            #expect(self.fileModes == [0o600])
            #expect(self.directoryModes == [0o700])
            #expect(!self.temporaryFiles.isEmpty)
            #expect(self.maximumFileCount <= 4)
            print("Rsync receiving modes: files=\(self.fileModes) directories=\(self.directoryModes) " +
                "nonempty files=\(self.filesObservedDuringWrite.count) temporary files=\(self.temporaryFiles.count) " +
                "maximum file count=\(self.maximumFileCount)")
        }
    }

    @Test func `system rsync keeps private modes during and after transfer for varied source modes`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try CodexRemoteLogStorage.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let temporary = root.appendingPathComponent("mirror")
        try CodexRemoteLogStorage.privateDirectory(source)
        try CodexRemoteLogStorage.privateDirectory(source.appendingPathComponent("sessions"))
        try CodexRemoteLogStorage.privateDirectory(source.appendingPathComponent("sessions/nested"))
        let modes = [0o444, 0o644, 0o664, 0o777]
        // Concentrate the roughly 5 MB payload in one file: at 1 MB/s its nonempty temporary file
        // remains observable for seconds, without requiring the sampler to catch every rename.
        let contents = modes.indices.map { index in
            Data(String(repeating: "{\"synthetic\":true}\n", count: index == 0 ? 262_144 : 1024).utf8)
        }
        let paths = modes.map { "sessions/nested/mode-\(String($0, radix: 8)).jsonl" }
        var fields = [
            "CODEX_LOGS_V1",
            "/synthetic/codex",
            "R",
            "sessions",
            "present",
            "D",
            "sessions",
            "D",
            "sessions/nested",
        ]
        for (index, path) in paths.enumerated() {
            let bytes = contents[index]
            let url = source.appendingPathComponent(path)
            try CodexRemoteLogStorage.privateFile(bytes, at: url)
            try FileManager.default.setAttributes([.posixPermissions: modes[index]], ofItemAtPath: url.path)
            fields += ["F", path, String(bytes.count), "stable-revision", CodexRemoteLogManifest.digest(bytes)]
        }
        fields += ["R", "archived_sessions", "missing", "END", ""]
        let manifest = fields.joined(separator: "\0")
        let observations = Observations()
        var limits = CodexRemoteLogMirror.Limits()
        limits.fileCount = paths.count
        limits.totalBytes = Int64(contents.reduce(0) { $0 + $1.count })
        let mirror = CodexRemoteLogMirror(environment: [:], temporaryRoot: temporary, limits: limits) { command in
            if command.kind == .manifest { return manifest }
            var arguments = command.arguments
            arguments[arguments.count - 2] = source.path + "/"
            let bandwidth = try #require(arguments.firstIndex(of: "--bwlimit=4096"))
            arguments[bandwidth] = "--bwlimit=1024"
            let localCommand = CodexRemoteLogMirror.Command(
                kind: .transfer,
                binary: CodexRemoteLogGuardianTests.builtCLIPath,
                arguments: arguments,
                environment: command.environment,
                outputBytes: command.outputBytes,
                lockDescriptor: command.lockDescriptor)
            let staging = try URL(fileURLWithPath: #require(arguments.last))
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await CodexRemoteLogMirrorProcess.run(localCommand) }
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        await observations.sample(staging)
                        try await Task.sleep(for: .microseconds(500))
                    }
                }
                defer { group.cancelAll() }
                return try await #require(group.next())
            }
        }
        try await mirror.withMirror(source: .init(host: "Fixture")) { snapshot in
            let received = try CodexRemoteLogStorage.verifyTree(
                snapshot.roots[0].deletingLastPathComponent(), limits: .init())
            #expect(received.count == paths.count)
            for (path, bytes) in zip(paths, contents) {
                let url = snapshot.roots[0].deletingLastPathComponent().appendingPathComponent(path)
                #expect(try Data(contentsOf: url) == bytes)
                #expect(try CodexRemoteLogStorage.attributes(url).st_mode & 0o777 == 0o600)
            }
        }
        await observations.verify()
        for (index, path) in paths.enumerated() {
            let url = source.appendingPathComponent(path)
            #expect(try Data(contentsOf: url) == contents[index])
            #expect(try CodexRemoteLogStorage.attributes(url).st_mode & 0o777 == modes[index])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }
}
