import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Minimal copy of the capture path used by ProviderVersionDetector.run().
/// The key detail: we set readabilityHandler but never close the underlying
/// fileHandleForReading, matching the original ProcessPipeCapture behavior.
/// Setting `closeOnFinish = true` emulates the fix.
final class LeakyPipeCapture {
    private let handle: FileHandle
    private let closeOnFinish: Bool
    private let condition = NSCondition()
    private var data = Data()
    private var activeCallbacks = 0
    private var isFinished = false
    private var isStopping = false

    init(pipe: Pipe, closeOnFinish: Bool = false) {
        self.handle = pipe.fileHandleForReading
        self.closeOnFinish = closeOnFinish
    }

    func start() {
        self.handle.readabilityHandler = { [weak self] handle in
            self?.handleReadableData(from: handle)
        }
    }

    func finish(timeout: TimeInterval) -> Data {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        self.condition.lock()
        while !self.isFinished, !self.isStopping {
            guard self.condition.wait(until: deadline) else { break }
        }
        self.condition.unlock()
        return self.stopAndSnapshot()
    }

    private func handleReadableData(from handle: FileHandle) {
        self.condition.lock()
        guard !self.isStopping else {
            self.condition.unlock()
            return
        }
        self.activeCallbacks += 1
        self.condition.unlock()

        let chunk = handle.availableData

        self.condition.lock()
        if chunk.isEmpty {
            self.isFinished = true
        } else {
            self.data.append(chunk)
        }
        self.activeCallbacks -= 1
        self.condition.broadcast()
        self.condition.unlock()

        if chunk.isEmpty {
            handle.readabilityHandler = nil
        }
    }

    private func stopAndSnapshot() -> Data {
        self.handle.readabilityHandler = nil

        let snapshot: Data
        self.condition.lock()
        self.isStopping = true
        while self.activeCallbacks > 0 {
            self.condition.wait()
        }
        self.isFinished = true
        snapshot = self.data
        self.condition.unlock()

        if self.closeOnFinish {
            try? self.handle.close()
        }
        return snapshot
    }
}

func countOpenFDs() -> Int {
    #if os(Linux)
    let path = "/proc/self/fd"
    #else
    let path = "/dev/fd"
    #endif
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
        return -1
    }
    return entries.count
}

func spawnOnce(closeOnFinish: Bool = false) {
    let proc = Process()
    #if os(Linux)
    proc.executableURL = URL(fileURLWithPath: "/bin/echo")
    #else
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/echo")
    #endif
    proc.arguments = ["hello"]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    let capture = LeakyPipeCapture(pipe: out, closeOnFinish: closeOnFinish)
    capture.start()

    do {
        try proc.run()
    } catch {
        return
    }
    proc.waitUntilExit()
    _ = capture.finish(timeout: 0.25)
}

func main() {
    let mode = CommandLine.arguments.dropFirst().first ?? "leak"
    switch mode {
    case "leak":
        runLeakRepro()
    case "emfile":
        runEMFILECrash()
    case "fixed":
        runFixedRepro()
    default:
        print("usage: Repro [leak|emfile|fixed]")
    }
}

func runLeakRepro() {
    let start = countOpenFDs()
    print("initial open fds: \(start)")

    for i in 0..<500 {
        spawnOnce(closeOnFinish: false)
        if i % 50 == 0 {
            print("round \(i): open fds = \(countOpenFDs())")
        }
    }

    print("final open fds: \(countOpenFDs())")
}

func runFixedRepro() {
    print("Running FIXED version (closes handle after capture)...")
    let start = countOpenFDs()
    print("initial open fds: \(start)")

    for i in 0..<500 {
        spawnOnce(closeOnFinish: true)
        if i % 50 == 0 {
            print("round \(i): open fds = \(countOpenFDs())")
        }
    }

    print("final open fds: \(countOpenFDs())")
}

func runEMFILECrash() {
    #if canImport(Darwin)
    var limit = rlimit(rlim_cur: 50, rlim_max: 50)
    let rc = setrlimit(RLIMIT_NOFILE, &limit)
    print("setrlimit -> \(rc)")
    var current = rlimit()
    getrlimit(RLIMIT_NOFILE, &current)
    print("current fd limit: cur=\(current.rlim_cur) max=\(current.rlim_max)")
    #endif

    var pipes: [Pipe] = []
    print("filling fd table...")
    for i in 0..<50 {
        let p = Pipe()
        pipes.append(p)
        if i % 10 == 0 {
            print("filled \(i) pipes, open fds = \(countOpenFDs())")
        }
    }

    print("open fds after fill: \(countOpenFDs())")
    print("attempting one more Pipe + readabilityHandler...")

    let p = Pipe()
    let capture = LeakyPipeCapture(pipe: p)
    capture.start() // on Linux corelibs this triggers precondition(_fd >= 0)
    print("unexpectedly survived")
}

main()
