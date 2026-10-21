import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
struct TTYProcessTreeProcfsReadLinuxTests {
    @Test
    func `procfs reader returns file content`() throws {
        let stat = try #require(TTYProcessTreeTerminator.readProcFile("/proc/self/stat"))
        #expect(stat.hasPrefix("\(getpid()) "))
    }

    @Test(arguments: [1, 4095, 4096, 4097, 10000])
    func `procfs reader preserves content across chunk boundaries`(byteCount: Int) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let content = String(repeating: "1", count: byteCount)
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(TTYProcessTreeTerminator.readProcFile(file.path) == content)
    }

    @Test
    func `procfs reader tells an empty file from a missing one`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(TTYProcessTreeTerminator.readProcFile(file.path)?.isEmpty == true)
        #expect(TTYProcessTreeTerminator.readProcFile(file.path + ".missing") == nil)
    }

    @Test
    func `procfs reader fails softly for invalid UTF8 and read errors`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0xFF]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(TTYProcessTreeTerminator.readProcFile(file.path) == nil)
        #expect(TTYProcessTreeTerminator.readProcFile("/proc/self") == nil)
    }

    @Test
    func `exited process has no child list or identity`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/true")
        process.environment = [:]
        try process.run()
        process.waitUntilExit()

        #expect(TTYProcessTreeTerminator.currentChildPIDs(of: process.processIdentifier).isEmpty)
        #expect(TTYProcessTreeTerminator.processIdentity(for: process.processIdentifier) == nil)
    }

    @Test
    func `child lookup finds a running child`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.environment = [:]
        try process.run()
        defer {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        #expect(TTYProcessTreeTerminator.currentChildPIDs(of: getpid()).contains(process.processIdentifier))
    }
}
#endif
