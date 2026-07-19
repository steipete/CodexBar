import Darwin
import Foundation

private enum WatchdogExitCode {
    static let usage: Int32 = 64
    static let spawnFailed: Int32 = 70
}

private nonisolated(unsafe) var globalChildPID: pid_t = 0
private nonisolated(unsafe) var globalShouldTerminate: Int32 = 0

private func usageAndExit() -> Never {
    fputs("Usage: CodexBarClaudeWatchdog -- <binary> [args...]\n", stderr)
    Darwin.exit(WatchdogExitCode.usage)
}

private func killProcessTree(childPID: pid_t, graceSeconds: TimeInterval = 0.5) {
    let pgid = getpgid(childPID)
    if pgid > 0 {
        kill(-pgid, SIGTERM)
    } else {
        kill(childPID, SIGTERM)
    }

    let deadline = Date().addingTimeInterval(graceSeconds)
    var status: Int32 = 0
    while Date() < deadline {
        let rc = waitpid(childPID, &status, WNOHANG)
        if rc == childPID { return }
        usleep(50000)
    }

    if pgid > 0 {
        kill(-pgid, SIGKILL)
    } else {
        kill(childPID, SIGKILL)
    }
}

private func exitCode(fromWaitStatus status: Int32) -> Int32 {
    // Swift can't import wait(2) macros (function-like macros). Use the classic encoding:
    // - low 7 bits: signal number (0 means exited)
    // - high byte: exit status (when exited)
    let low = status & 0x7F
    if low == 0 {
        return (status >> 8) & 0xFF
    }
    if low != 0x7F {
        return 128 + low
    }
    return 1
}

let argv = CommandLine.arguments
guard let sep = argv.firstIndex(of: "--") else { usageAndExit() }
let childArgs = Array(argv[(sep + 1)...])
guard !childArgs.isEmpty else { usageAndExit() }

let childBinary = childArgs[0]
let childArgv = childArgs

let spawnResult: Int32 = childArgv.withUnsafeBufferPointer { buffer in
    var cStrings: [UnsafeMutablePointer<CChar>?] = buffer
        .map { strdup($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { if let p = $0 { free(p) } } }

    return cStrings.withUnsafeMutableBufferPointer { cBuffer in
        var pid: pid_t = 0
        let rc: Int32 = childBinary.withCString { childPath in
            posix_spawnp(&pid, childPath, nil, nil, cBuffer.baseAddress, environ)
        }
        if rc == 0, pid > 0 {
            globalChildPID = pid
        }
        return rc
    }
}

guard spawnResult == 0, globalChildPID > 0 else {
    fputs("CodexBarClaudeWatchdog: failed to spawn child: \(childBinary) (rc=\(spawnResult))\n", stderr)
    Darwin.exit(WatchdogExitCode.spawnFailed)
}

_ = setpgid(globalChildPID, globalChildPID)

private func terminateChild() {
    if globalChildPID > 0 {
        killProcessTree(childPID: globalChildPID)
    }
}

private func handleTerminationSignal(_ sig: Int32) {
    globalShouldTerminate = sig
}

signal(SIGTERM, handleTerminationSignal)
signal(SIGINT, handleTerminationSignal)
signal(SIGHUP, handleTerminationSignal)

var status: Int32 = 0
while true {
    let rc = waitpid(globalChildPID, &status, WNOHANG)
    if rc == globalChildPID {
        Darwin.exit(exitCode(fromWaitStatus: status))
    }

    if globalShouldTerminate != 0 {
        let sig = globalShouldTerminate
        terminateChild()
        _ = waitpid(globalChildPID, &status, 0)
        Darwin.exit(128 + sig)
    }

    if getppid() == 1 {
        terminateChild()
        _ = waitpid(globalChildPID, &status, 0)
        Darwin.exit(exitCode(fromWaitStatus: status))
    }

    usleep(200_000)
}
