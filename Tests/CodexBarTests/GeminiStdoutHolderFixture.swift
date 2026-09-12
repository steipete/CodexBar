import Foundation
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The test owns the holder Process before the producer can hand it a stdout descriptor.
/// No descendant discovery or PID file is needed to clean up a failed producer.
final class GeminiStdoutHolderFixture {
    static let setupBudget: TimeInterval = 10

    enum Fault: String {
        case none, lateReady, neverReady, earlyExit, partialReady, malformedReady, ignoreControl, launchFailure
    }

    enum SetupCause: Equatable {
        case preparationFailed, launchFailed, timedOut, exitedBeforeReady, incompleteReadiness, malformedReadiness
    }

    enum Readiness: Equatable {
        case pending, ready, failed(SetupCause)
    }

    struct CleanupOutcome: Equatable {
        enum Phase { case controlClosed, reaped, capturesStopped }
        let launched: Bool
        let forcedTermination: Bool
        let terminationStatus: Int32?
        let terminationReason: Process.TerminationReason?
        let stdout: Data
        let stderr: Data
        let phases: [Phase]

        var succeeded: Bool {
            self.launched && !self.forcedTermination && self.terminationStatus == 0 &&
                self.phases == [.controlClosed, .reaped, .capturesStopped]
        }
    }

    struct SetupError: Error {
        let cause: SetupCause
        let underlyingError: Error?
        let elapsed: TimeInterval
        let readinessBytes: Data
        let reachedEOF: Bool
        let observedExit: Bool
        let cleanup: CleanupOutcome
    }

    let process = Process()
    let pidFile: URL
    private let helper: URL
    private let socketPath: String
    private let control = Pipe()
    private let signal = HolderReadinessSignal()
    private let output = Pipe()
    private let errors = Pipe()
    private let capture: ProcessPipeCapture
    private let errorCapture: ProcessPipeCapture
    private var started = false
    private var cleanupOutcome: CleanupOutcome?

    private let environment = [
        "PATH": "/usr/bin:/bin",
        "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
    ]

    init(
        root: URL,
        readinessDelay: TimeInterval = 0,
        fault: Fault = .none,
        readinessElapsed: (TimeInterval, Data) -> TimeInterval = { elapsed, _ in elapsed }) throws
    {
        self.helper = root.appendingPathComponent("stdout-holder.py")
        self.socketPath = root.appendingPathComponent("s").path
        self.pidFile = root.appendingPathComponent("holder.pid")
        let signal = self.signal
        self.capture = ProcessPipeCapture(pipe: self.output, onData: { signal.notify() })
        self.errorCapture = ProcessPipeCapture(pipe: self.errors, onData: { signal.notify() })
        let startedAt = ProcessInfo.processInfo.systemUptime
        var cause = SetupCause.preparationFailed
        // Use the system interpreter directly and isolate its module search from user configuration.
        self.process.executableURL = fault == .launchFailure
            ? root.appendingPathComponent("missing-interpreter") : URL(fileURLWithPath: "/usr/bin/python3")
        self.process.arguments = [
            "-I", self.helper.path, "hold", self.socketPath, String(readinessDelay), fault.rawValue,
        ]
        self.process.environment = self.environment
        self.process.standardInput = self.control
        self.process.standardOutput = self.output
        self.process.standardError = self.errors
        self.process.terminationHandler = { _ in signal.recordExit() }
        do {
            try Self.script.write(to: self.helper, atomically: true, encoding: .utf8)
            cause = .launchFailed
            try self.process.run()
        } catch {
            throw self.setupError(cause, underlyingError: error, startedAt: startedAt)
        }
        self.started = true
        self.control.fileHandleForReading.closeFile()
        self.output.fileHandleForWriting.closeFile()
        self.errors.fileHandleForWriting.closeFile()
        self.capture.start()
        self.errorCapture.start()
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let captureState = self.captureObservation()
            let observation = Self.observeReadiness(
                captureState.bytes,
                ended: captureState.eof,
                elapsed: max(elapsed, readinessElapsed(elapsed, self.errorCapture.currentSnapshot())))
            switch observation {
            case .ready: return
            case let .failed(cause): throw self.setupError(cause, startedAt: startedAt)
            case .pending: self.signal.waitForChange()
            }
        }
    }

    struct CaptureObservation {
        let bytes: Data
        let eof: Bool
        let exited: Bool
    }

    static func captureObservation(
        snapshot: () -> Data,
        reachedEOF: () -> Bool,
        observedExit: () -> Bool) -> CaptureObservation
    {
        // EOF is monotonic and follows the final append. Never pair a newly observed EOF with older bytes.
        let eof = reachedEOF()
        let exited = observedExit()
        let bytes = snapshot()
        return CaptureObservation(bytes: bytes, eof: eof, exited: exited)
    }

    private func captureObservation() -> CaptureObservation {
        Self.captureObservation(
            snapshot: self.capture.currentSnapshot,
            reachedEOF: { self.capture.reachedEOF },
            observedExit: { self.signal.hasExited })
    }

    static func observeReadiness(_ bytes: Data, ended: Bool, elapsed: TimeInterval) -> Readiness {
        if elapsed >= self.setupBudget { return .failed(.timedOut) }
        if let newline = bytes.firstIndex(of: 10) {
            return bytes[...newline] == Data("ready\n".utf8) ? .ready : .failed(.malformedReadiness)
        }
        if ended { return .failed(bytes.isEmpty ? .exitedBeforeReady : .incompleteReadiness) }
        return .pending
    }

    private func setupError(
        _ cause: SetupCause,
        underlyingError: Error? = nil,
        startedAt: TimeInterval) -> SetupError
    {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let captureState = self.captureObservation()
        return SetupError(
            cause: cause,
            underlyingError: underlyingError,
            elapsed: elapsed,
            readinessBytes: captureState.bytes,
            reachedEOF: captureState.eof,
            observedExit: captureState.exited,
            cleanup: self.cleanup())
    }

    func runProducer(pidFile: URL? = nil, blockAfterAcknowledgment: Bool = false) -> String? {
        GeminiStatusProbe.runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                "-I", self.helper.path, blockAfterAcknowledgment ? "produce-timeout" : "produce",
                self.socketPath, (pidFile ?? self.pidFile).path,
            ],
            environment: self.environment,
            timeout: 2)
    }

    var producerDiagnostics: String {
        (try? String(contentsOfFile: self.socketPath + ".error", encoding: .utf8)) ?? ""
    }

    @discardableResult
    func cleanup() -> CleanupOutcome {
        if let cleanupOutcome = self.cleanupOutcome { return cleanupOutcome }
        var phases: [CleanupOutcome.Phase] = [.controlClosed]
        self.control.fileHandleForWriting.closeFile()
        var forced = false
        if self.started {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while self.process.isRunning, !self.signal.hasExited, ProcessInfo.processInfo.systemUptime < deadline {
                self.signal.waitForChange()
            }
            if self.process.isRunning {
                forced = true
                _ = kill(self.process.processIdentifier, SIGKILL)
            }
            self.process.waitUntilExit()
            phases.append(.reaped)
        } else {
            self.control.fileHandleForReading.closeFile()
            self.output.fileHandleForWriting.closeFile()
            self.errors.fileHandleForWriting.closeFile()
        }
        // A readiness timeout never closes stdout: drain until the owned child has been reaped.
        let stdout = self.capture.finishSynchronously(timeout: self.started ? 1 : 0)
        let stderr = self.errorCapture.finishSynchronously(timeout: self.started ? 1 : 0)
        phases.append(.capturesStopped)
        let outcome = CleanupOutcome(
            launched: self.started,
            forcedTermination: forced,
            terminationStatus: self.started ? self.process.terminationStatus : nil,
            terminationReason: self.started ? self.process.terminationReason : nil,
            stdout: stdout,
            stderr: stderr,
            phases: phases)
        self.cleanupOutcome = outcome
        return outcome
    }

    deinit {
        self.cleanup()
    }

    private static let script = #"""
    import array
    import os
    import select
    import socket
    import stat
    import sys
    import traceback

    mode, path = sys.argv[1:3]
    if mode.startswith("produce"):
        def record_failure(kind, error, stack):
            with open(path + ".error", "w") as handle:
                traceback.print_exception(kind, error, stack, file=handle)
        sys.excepthook = record_failure

    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
        if mode == "hold":
            channel.bind(path)
            fault = sys.argv[4]
            if fault == "earlyExit":
                sys.exit(23)
            if fault == "partialReady":
                print("rea", end="", flush=True)
                sys.exit(0)
            if fault == "malformedReady":
                print("wrong", flush=True)
                assert os.read(0, 1) == b""
                sys.exit(0)
            if fault in ("lateReady", "neverReady"):
                print("armed", file=sys.stderr, flush=True)
                assert os.read(0, 1) == b""
                if fault == "lateReady":
                    print("ready", flush=True)
                sys.exit(0)
            select.select([sys.stdin], [], [], float(sys.argv[3]))
            print("ready", flush=True)
            held = []
            try:
                while True:
                    inputs = [channel] if fault == "ignoreControl" else [channel, sys.stdin]
                    readable, _, _ = select.select(inputs, [], [])
                    if sys.stdin in readable:
                        assert os.read(0, 1) == b""
                        break
                    _, ancillary, flags, sender = channel.recvmsg(1, socket.CMSG_SPACE(array.array("i").itemsize))
                    assert flags == 0 and len(ancillary) == 1
                    level, kind, data = ancillary[0]
                    assert (level, kind) == (socket.SOL_SOCKET, socket.SCM_RIGHTS)
                    descriptors = array.array("i")
                    descriptors.frombytes(data)
                    held.extend(descriptors)
                    assert len(descriptors) == 1 and stat.S_ISFIFO(os.fstat(descriptors[0]).st_mode)
                    channel.sendto(str(os.getpid()).encode(), sender)
            finally:
                for descriptor in held:
                    os.close(descriptor)
        else:
            assert mode in ("produce", "produce-timeout")
            channel.bind(path + ".p")
            channel.settimeout(2)
            channel.connect(path)
            channel.sendmsg([b"x"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [1]))])
            holder_pid = channel.recv(32).decode()
            # The acknowledgement proves the owned holder has the writer before any output is printed.
            with open(sys.argv[3], "w") as handle:
                handle.write(holder_pid)
            if mode == "produce-timeout":
                select.select([], [], [], 30)
            print("/tmp/gemini-package", flush=True)
            print("ignored trailing output", flush=True)
    """#
}

/// Durable exit observation lets readiness and cleanup inspect the same event without consuming it.
private final class HolderReadinessSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var exited = false

    var hasExited: Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        return self.exited
    }

    func recordExit() {
        self.condition.lock()
        self.exited = true
        self.condition.broadcast()
        self.condition.unlock()
    }

    func notify() {
        self.condition.lock()
        self.condition.broadcast()
        self.condition.unlock()
    }

    func waitForChange() {
        self.condition.lock()
        _ = self.condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        self.condition.unlock()
    }
}
