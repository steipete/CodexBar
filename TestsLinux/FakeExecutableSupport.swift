import Foundation

/// Installs a fake CLI on disk for tests that need to launch one.
///
/// Executing a file the test process just wrote races with every other test that
/// spawns a child: the fork inherits the still-open write descriptor and execve
/// fails with `ETXTBSY`. Swift Testing runs the suite concurrently inside one
/// process, so that window is wide, and Linux Foundation has no
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` to close it.
///
/// Writing the body as data and executing a checked-in trampoline keeps execve
/// away from every file this process wrote.
enum FakeExecutable {
    /// Writes `body` beside `url` and links `url` to the checked-in trampoline.
    static func install(_ body: String, at url: URL) throws {
        try Data(body.utf8).write(to: url.appendingPathExtension("sh"))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: self.trampoline())
    }

    private static func trampoline() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = directory.appending(path: "Tests/CodexBarTests/Fixtures/Scripts/exec-trampoline.sh")
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "FakeExecutable", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate exec-trampoline.sh from \(#filePath)",
        ])
    }
}
