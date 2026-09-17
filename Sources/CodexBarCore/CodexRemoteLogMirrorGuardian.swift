#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

package final class CodexRemoteLogGuardianControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    package init() {}
    package func cancel() { self.lock.withLock { self.cancelled = true } }
    package var isCancelled: Bool {
        self.lock.withLock { self.cancelled }
    }
}

/// Internal entry point in the already packaged CLI. This process owns the receiving process group
/// and the inherited request lock independently of the App's lifetime.
package enum CodexRemoteLogGuardian {
    package static let argument = "--internal-codex-log-guardian"
    static let timeoutStatus: Int32 = 71
    static let cancelledStatus: Int32 = 72
    static let budgetStatus: Int32 = 73

    static func executable(environment: [String: String]) -> String {
        #if DEBUG
        if let path = environment["CODEXBAR_SSH_GUARDIAN_PATH"], path.hasPrefix("/") { return path }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("CodexBarCLI")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
            directory.deleteLastPathComponent()
        }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI").path
    }

    package static func run(
        arguments: [String],
        environment: [String: String],
        control: CodexRemoteLogGuardianControl) async -> Int32
    {
        guard arguments.count >= 8, arguments[0] == self.argument,
              let seconds = Double(arguments[1]), seconds > 0, seconds <= 300,
              let fileBytes = Int64(arguments[2]), fileBytes > 0, fileBytes <= 256 * 1024 * 1024,
              let totalBytes = Int64(arguments[3]), totalBytes > 0, totalBytes <= 512 * 1024 * 1024,
              let fileCount = Int(arguments[4]), fileCount > 0, fileCount <= 10000,
              arguments[5] == "--", let destination = arguments.last,
              self.hasInheritedRequestLock()
        else { return 74 }
        var limits = CodexRemoteLogMirror.Limits()
        limits.fileBytes = fileBytes
        limits.totalBytes = totalBytes
        limits.fileCount = fileCount
        let staging = URL(fileURLWithPath: destination, isDirectory: true)
        var receiver = "/usr/bin/rsync"
        #if DEBUG
        if let fixture = environment["CODEXBAR_SSH_GUARDIAN_RECEIVER"], fixture.hasPrefix("/") {
            receiver = fixture
        }
        #endif
        // Conservative across sh implementations: 512-byte shells stop earlier, never later.
        let blocks = max(1, (fileBytes + 1023) / 1024)
        let output = Pipe()
        let errors = Pipe()
        let stdout = ProcessPipeCapture(pipe: output, maxBytes: 65537)
        let stderr = ProcessPipeCapture(pipe: errors, maxBytes: 65537)
        let process: SpawnedProcessGroup
        do {
            process = try SpawnedProcessGroup.launch(
                binary: "/bin/sh",
                arguments: ["-c", "umask 077; ulimit -f \(blocks) || exit 125; exec \"$@\"", "guardian", receiver]
                    + arguments.dropFirst(6),
                environment: environment,
                stdoutPipe: output,
                stderrPipe: errors,
                retainExitedRoot: true)
        } catch {
            stdout.stop()
            stderr.stop()
            return 74
        }
        stdout.start()
        stderr.start()
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var failure: Int32?
        while process.isRunning {
            if control.isCancelled { failure = Self.cancelledStatus; break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = Self.timeoutStatus; break }
            if stdout.currentSnapshot().count > 65536 || stderr.currentSnapshot().count > 65536 {
                failure = Self.budgetStatus
                break
            }
            do { _ = try CodexRemoteLogStorage.verifyTree(staging, limits: limits) } catch {
                failure = Self.budgetStatus; break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Includes successful receiver exit: background writers must also be gone before fd 0 unlocks.
        await process.terminateAndDrain()
        _ = await stdout.finish(timeout: .seconds(1))
        _ = await stderr.finish(timeout: .seconds(1))
        return failure ?? (process.terminationStatus == 0 ? 0 : 74)
    }

    private static func hasInheritedRequestLock() -> Bool {
        var info = stat()
        return fstat(STDIN_FILENO, &info) == 0 && CodexRemoteLogStorage.isRegular(info)
            && info.st_uid == getuid() && info.st_mode & 0o777 == 0o600
            && flock(STDIN_FILENO, LOCK_EX | LOCK_NB) == 0
    }
}
