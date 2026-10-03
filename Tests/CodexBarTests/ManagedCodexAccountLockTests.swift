import Foundation
import Testing
@testable import CodexBarCore

struct ManagedCodexAccountLockTests {
    @Test
    func `account store refuses another process lock and recovers after release`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedCodexAccountStore(fileURL: root.appendingPathComponent("accounts.json"))
        let lock = try #require(store.lockURL)
        let ready = Pipe()
        let release = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            "import fcntl,sys; f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX); "
                + "print('ready',flush=True); sys.stdin.read(1)",
            lock.path,
        ]
        child.environment = ["PATH": "/usr/bin:/bin"]
        child.standardOutput = ready
        child.standardInput = release
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let signal = ready.fileHandleForReading.availableData
        #expect(try #require(String(bytes: signal, encoding: .utf8)).contains("ready"))
        #expect(throws: ManagedCodexAccountLockError.busy) {
            try store.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: []))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts.json").path))
        try release.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        child.waitUntilExit()
        try store.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: []))
        #expect(try store.loadAccounts().accounts.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: lock.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test
    func `account store refuses symlink lock files`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedCodexAccountStore(fileURL: root.appendingPathComponent("accounts.json"))
        let target = root.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: #require(store.lockURL), withDestinationURL: target)
        #expect(throws: ManagedCodexAccountLockError.unavailable) {
            try store.storeAccounts(ManagedCodexAccountSet(version: 3, accounts: []))
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
    }
}
