import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import CodexBarCore

struct AntigravityPortDiscoveryTests {
    @Test(arguments: [
        "printf 'lsof: WARNING: cannot stat namespace filesystem\\n' >&2; exit 1",
        "exit 1",
        "exit 0",
        "printf 'lsof: failed\\n' >&2; exit 2",
    ])
    func `failed or empty lsof recovers only process owned proc listeners`(script: String) async throws {
        let fixture = try Fixture(script: script)
        defer { fixture.remove() }
        #expect(try await fixture.ports() == [8080])
    }

    @Test
    func `missing lsof executable recovers through proc`() async throws {
        let fixture = try Fixture(script: "exit 0")
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.lsof)
        #expect(try await fixture.ports() == [8080])
    }

    @Test
    func `CLI readiness retries namespace warnings until the proc listener appears`() async throws {
        let fixture = try Fixture(script: "printf 'lsof: WARNING: namespace unavailable\\n' >&2; exit 1")
        defer { fixture.remove() }
        let socketLink = fixture.root.appendingPathComponent("42/fd/7")
        try FileManager.default.removeItem(at: socketLink)
        let attempts = DiscoveryAttempts()
        let snapshot = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
            pid: 42,
            deadline: Date().addingTimeInterval(15),
            dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                pollIntervalNanoseconds: 0,
                listeningPorts: { _, timeout in
                    if await attempts.next() == 2 {
                        try FileManager.default.createSymbolicLink(
                            atPath: socketLink.path, withDestinationPath: "socket:[111111]")
                    }
                    return try await fixture.ports(timeout: timeout)
                },
                drainOutput: { Data() },
                fetchSnapshot: { ports in
                    #expect(ports == [8080])
                    return AntigravityStatusSnapshot(
                        modelQuotas: [AntigravityModelQuota(
                            label: "Gemini Pro", modelId: "gemini-pro", remainingFraction: 0.5,
                            resetTime: nil, resetDescription: nil)],
                        accountEmail: "fixture@example.com", accountPlan: "Pro", source: .local)
                }))
        #expect(snapshot.accountEmail == "fixture@example.com")
        #expect(await attempts.count == 2)
    }

    @Test
    func `successful lsof retains precedence over proc`() async throws {
        let fixture = try Fixture(script: "printf 'agy 42 user TCP 127.0.0.1:4242 (LISTEN)\\n'")
        defer { fixture.remove() }
        #expect(try await fixture.ports() == [4242])
    }

    @Test
    func `failed proc fallback preserves lsof diagnostic`() async throws {
        let fixture = try Fixture(script: "printf 'namespace warning\\n' >&2; exit 1")
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("42/fd/7"))
        do {
            _ = try await fixture.ports()
            Issue.record("Expected original lsof failure when neither source has a listener")
        } catch let error as AntigravityPortDiscoveryPendingError {
            guard case let SubprocessRunnerError.nonZeroExit(code, stderr) = error.underlyingError else {
                Issue.record("Expected the original lsof diagnostic")
                return
            }
            #expect(code == 1)
            #expect(stderr == "namespace warning\n")
            #expect(error.localizedDescription == error.underlyingError.localizedDescription)
        }
    }

    @Test
    func `absent lsof and empty proc retains no ports error`() async throws {
        let fixture = try Fixture(script: "exit 0")
        defer { fixture.remove() }
        await #expect(throws: AntigravityStatusProbeError.portDetectionFailed("no listening ports found")) {
            try await AntigravityStatusProbe.linuxListeningPorts(
                pid: 999,
                timeout: 5,
                lsof: nil,
                procRoot: fixture.root.path)
        }
    }

    @Test(arguments: ["exit 0", "exit 1"])
    func `ordinary empty discovery retains the existing no ports classification`(script: String) async throws {
        let fixture = try Fixture(script: script)
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("42/fd/7"))
        await #expect(throws: AntigravityStatusProbeError.portDetectionFailed("no listening ports found")) {
            try await fixture.ports()
        }
    }

    @Test
    func `cancelled discovery cannot recover through proc`() async throws {
        let fixture = try Fixture(script: "exit 1")
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AntigravityStatusProbe.linuxListeningPorts(
                pid: 42,
                timeout: 5,
                lsof: nil,
                procRoot: fixture.root.path)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func `lsof timeout cannot recover through proc`() async throws {
        let fixture = try Fixture(script: "exec sleep 10")
        defer { fixture.remove() }
        do {
            _ = try await fixture.ports(timeout: 0.1)
            Issue.record("Expected lsof deadline to remain authoritative")
        } catch let SubprocessRunnerError.timedOut(label) {
            #expect(label == "antigravity-lsof")
        }
    }

    #if canImport(Glibc) || canImport(Musl)
    @Test
    func `Linux proc recovers a real listener after lsof namespace warnings`() async throws {
        let fixture = try Fixture(script: "printf 'lsof: WARNING: namespace unavailable\\n' >&2; exit 1")
        defer { fixture.remove() }
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let ports = try await AntigravityStatusProbe.linuxListeningPorts(
            pid: Int(getpid()), timeout: 5, lsof: fixture.lsof.path)
        #expect(ports.contains(Int(UInt16(bigEndian: address.sin_port))))
    }
    #endif

    private actor DiscoveryAttempts {
        private(set) var count = 0

        func next() -> Int {
            self.count += 1
            return self.count
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let lsof: URL

        init(script: String) throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-port-discovery-\(UUID().uuidString)")
            self.lsof = self.root.appendingPathComponent("lsof")
            let files = FileManager.default
            try files.createDirectory(at: self.root.appendingPathComponent("42/fd"), withIntermediateDirectories: true)
            try files.createDirectory(at: self.root.appendingPathComponent("42/net"), withIntermediateDirectories: true)
            try files.createSymbolicLink(
                atPath: self.root.appendingPathComponent("42/fd/7").path,
                withDestinationPath: "socket:[111111]")
            let table = """
            sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode
            0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 111111
            1: 0100007F:C000 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 999999
            """
            try Data(table.utf8).write(to: self.root.appendingPathComponent("42/net/tcp"))
            try FakeExecutable.install("#!/bin/sh\n\(script)\n", at: self.lsof)
        }

        func ports(timeout: TimeInterval = 5) async throws -> [Int] {
            try await AntigravityStatusProbe.linuxListeningPorts(
                pid: 42, timeout: timeout, lsof: self.lsof.path, procRoot: self.root.path)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
