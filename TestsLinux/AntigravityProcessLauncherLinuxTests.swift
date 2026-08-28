#if canImport(Glibc) || canImport(Musl)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import CodexBarCore

struct AntigravityProcessLauncherLinuxTests {
    @Test
    func `pty launcher uses home and closes unrelated descriptors`() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let inheritedSourceFD = open("/dev/null", O_RDONLY)
        guard inheritedSourceFD >= 0 else {
            Issue.record("Failed to open descriptor fixture")
            return
        }
        defer { close(inheritedSourceFD) }
        let inheritedFD = fcntl(inheritedSourceFD, F_DUPFD, 200)
        guard inheritedFD >= 200 else {
            Issue.record("Failed to duplicate descriptor fixture")
            return
        }
        defer { close(inheritedFD) }

        let outputURL = tempDirectory.appendingPathComponent("result.txt")
        let scriptURL = tempDirectory.appendingPathComponent("probe.sh")
        let script = """
        #!/bin/sh
        pwd > \(outputURL.path)
        if [ -e /proc/self/fd/\(inheritedFD) ]; then
          echo inherited >> \(outputURL.path)
        else
          echo closed >> \(outputURL.path)
        fi
        """
        // Direct writes close the executable before spawn; atomic replacement can race with exec on overlay
        // filesystems.
        try Data(script.utf8).write(to: scriptURL)
        #expect(chmod(scriptURL.path, 0o700) == 0)

        let handle = try AntigravityPTYProcessLauncher().launch(binary: scriptURL.path)
        defer {
            handle.killRoot()
            handle.terminateTree(signal: SIGKILL, knownDescendants: [])
            handle.closePTY()
        }

        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: outputURL.path),
               let output = try? String(contentsOf: outputURL, encoding: .utf8)
            {
                let lines = output
                    .split(separator: "\n")
                    .map(String.init)
                if lines.count >= 2, output.hasSuffix("\n") { break }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let lines = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines == [NSHomeDirectory(), "closed"])
    }
}
#endif
