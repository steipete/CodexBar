import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
@Suite(.serialized)
struct ProcessPipeCaptureLinuxTests {
    @Test
    func `ProcessPipeCapture releases its pipe read end after capture`() throws {
        let initialFDs = try countOpenFDs()
        for _ in 0..<100 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/echo")
            proc.arguments = ["hello"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice

            let capture = ProcessPipeCapture(pipe: out)
            capture.start()
            try proc.run()
            proc.waitUntilExit()
            _ = capture.finishSynchronously(timeout: 0.25)
        }
        let finalFDs = try countOpenFDs()

        // Allow a small tolerance for unrelated fd churn, but ensure we are
        // not leaking pipe read ends (which would show as ~100 extra fds).
        #expect(finalFDs - initialFDs <= 15)
    }
}

private func countOpenFDs() throws -> Int {
    let entries = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
    return entries.count
}
#endif
