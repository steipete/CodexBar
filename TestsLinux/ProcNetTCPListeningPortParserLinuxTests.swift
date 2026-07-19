import Foundation
import Testing
@testable import CodexBarCore

/// Tests for the `/proc/<pid>/net/tcp` listening-port parser used on Linux as a
/// fallback for Antigravity CLI port detection when `lsof` is unavailable.
struct ProcNetTCPListeningPortParserLinuxTests {
    /// Two loopback LISTEN sockets (inodes 111111, 222222) and one established
    /// connection (inode 333333, st 01) that must be ignored.
    private static let sample = """
      sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
       0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111111 1 0000000000000000 100 0 0 10 0
       1: 0100007F:C000 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222222 1 0000000000000000 100 0 0 10 0
       2: 0100007F:1F91 0100007F:E1F0 01 00000000:00000000 00:00000000 00000000  1000        0 333333 1 0000000000000000 100 0 0 10 0
    """

    @Test
    func `returns listening ports for owned socket inodes`() {
        let ports = ProcNetTCPListeningPortParser.listeningPorts(
            Self.sample, socketInodes: ["111111", "222222"])
        #expect(ports == [8080, 49152])
    }

    @Test
    func `parses tcp6 and deduplicates ports across tables`() {
        let tcp6 = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000000000000:C000 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222222
        """
        let tcpPorts = ProcNetTCPListeningPortParser.listeningPorts(
            Self.sample, socketInodes: ["222222"])
        let tcp6Ports = ProcNetTCPListeningPortParser.listeningPorts(
            tcp6, socketInodes: ["222222"])
        #expect(tcpPorts.union(tcp6Ports) == [49152])
    }

    @Test
    func `ignores malformed and out of range ports`() {
        let malformed = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:NOTHEX 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111111
           1: 0100007F:10000 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111111
           2: missing-columns
        """
        #expect(ProcNetTCPListeningPortParser.listeningPorts(
            malformed, socketInodes: ["111111"]).isEmpty)
        #expect(ProcNetTCPListeningPortParser.listeningPorts(
            "header only", socketInodes: ["111111"]).isEmpty)
    }

    @Test
    func `accepts a headerless proc row`() {
        let row = Self.sample.split(separator: "\n")[1]
        #expect(ProcNetTCPListeningPortParser.listeningPorts(
            String(row), socketInodes: ["111111"]) == [8080])
    }

    @Test
    func `ignores listening sockets owned by other processes`() {
        let ports = ProcNetTCPListeningPortParser.listeningPorts(
            Self.sample, socketInodes: ["999999"])
        #expect(ports.isEmpty)
    }

    @Test
    func `ignores non listening sockets`() {
        // inode 333333 is an established (st 01) socket, not LISTEN.
        let ports = ProcNetTCPListeningPortParser.listeningPorts(
            Self.sample, socketInodes: ["333333"])
        #expect(ports.isEmpty)
    }

    @Test
    func `parses socket inode from FD symlink destination`() {
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "socket:[12345]") == "12345")
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "/dev/pts/0") == nil)
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "anon_inode:[eventpoll]") == nil)
        #expect(ProcNetTCPListeningPortParser.socketInode(fromLink: "socket:[]") == nil)
    }

    @Test
    func `reads process scoped TCP tables`() throws {
        let fileManager = FileManager.default
        let procRoot = fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-proc-\(UUID().uuidString)")
        let processRoot = procRoot.appendingPathComponent("42")
        let fdDirectory = processRoot.appendingPathComponent("fd")
        let netDirectory = processRoot.appendingPathComponent("net")
        let callerNetDirectory = procRoot.appendingPathComponent("net")
        try fileManager.createDirectory(at: fdDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: netDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: callerNetDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: procRoot) }

        try fileManager.createSymbolicLink(
            atPath: fdDirectory.appendingPathComponent("7").path,
            withDestinationPath: "socket:[111111]")
        try Self.sample.write(
            to: netDirectory.appendingPathComponent("tcp"),
            atomically: true,
            encoding: .utf8)
        try Self.sample.replacingOccurrences(of: ":1F90", with: ":C001").write(
            to: callerNetDirectory.appendingPathComponent("tcp"),
            atomically: true,
            encoding: .utf8)

        #expect(AntigravityStatusProbe.procListeningPorts(
            pid: 42,
            procRoot: procRoot.path) == [8080])
    }
}
