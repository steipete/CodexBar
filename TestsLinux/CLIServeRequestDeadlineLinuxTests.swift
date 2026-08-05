// `TestsLinux` is declared unconditionally in Package.swift, so this file is also
// compiled on macOS. The raw socket calls below are Linux-only, so gate the whole
// file the same way the other syscall suites here do.
#if canImport(Glibc) || canImport(Musl)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import CodexBarCLI

/// `readRequest` bounds each `recv` but not the request as a whole.
///
/// A client that keeps trickling bytes just inside the per-read window never trips
/// that timeout, so it holds its connection — and the cooperative-executor thread
/// serving it — for as long as it likes. Both the Host allowlist and the bearer
/// token are checked only after the head has been read, so a few such clients
/// exhaust `maximumConnections` entirely pre-auth.
///
/// A client that simply goes silent is *not* enough to show this: the existing
/// per-read timeout closes it. The clients here keep sending.
@Suite(.serialized)
struct CLIServeRequestDeadlineLinuxTests {
    private final class ListeningSignal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var signalled = false

        func signal() {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.signalled else { return }
            self.signalled = true
            self.semaphore.signal()
        }

        func wait() {
            self.semaphore.wait()
        }
    }

    /// A connection that dribbles one byte at a time, fast enough that the per-read
    /// timeout never fires, but never completing the header block.
    private final class TricklingClient: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var stopped = false

        init?(port: UInt16) {
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            guard fd >= 0 else { return nil }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                    connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(fd)
                return nil
            }
            self.fd = fd
        }

        /// Sends a header byte every `intervalSeconds`, well inside the 5s per-read
        /// window, so `waitForReadable` keeps succeeding.
        func start(intervalSeconds: Double) {
            Thread.detachNewThread { [self] in
                // A header line that never terminates: no CRLFCRLF is ever sent.
                let filler = Array("X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".utf8)
                var index = 0
                while true {
                    self.lock.lock()
                    let done = self.stopped
                    self.lock.unlock()
                    if done { return }

                    var byte = filler[index % filler.count]
                    index += 1
                    let sent = send(self.fd, &byte, 1, 0)
                    if sent <= 0 { return }
                    Thread.sleep(forTimeInterval: intervalSeconds)
                }
            }
        }

        func stop() {
            self.lock.lock()
            self.stopped = true
            self.lock.unlock()
            close(self.fd)
        }
    }

    /// Issues a complete request; returns seconds until a response, or nil on timeout.
    private static func probeHealth(port: UInt16, timeoutSeconds: Int) -> Double? {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let started = DispatchTime.now().uptimeNanoseconds
        let request = Array("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

        var buffer = [UInt8](repeating: 0, count: 256)
        let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard received > 0 else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9
    }

    @Test
    func `trickling clients cannot hold connection slots indefinitely`() async throws {
        let connectionCap = 3
        let listening = ListeningSignal()
        let server = CLILocalHTTPServer(
            host: "127.0.0.1",
            port: 0,
            allowedHosts: .loopbackOnly,
            maximumConnections: connectionCap)
        { _ in
            CLILocalHTTPResponse(status: .ok, body: Data(#"{"ok":true}"#.utf8))
        }

        let task = Task { try await server.run { listening.signal() } }
        listening.wait()
        let port = try #require(server.listeningPort)

        // Occupy every slot with clients that keep sending, so the per-read timeout
        // never fires for them.
        var clients: [TricklingClient] = []
        for _ in 0..<connectionCap {
            if let client = TricklingClient(port: port) {
                client.start(intervalSeconds: 1.0)
                clients.append(client)
            }
        }
        #expect(clients.count == connectionCap, "fixture sanity: all trickling clients connected")

        try await Task.sleep(nanoseconds: 500_000_000)

        // Over-cap connections are dropped immediately rather than queued, so a
        // legitimate client has to retry until a slot frees. With an overall
        // deadline the trickling clients are evicted and one becomes available;
        // without one they hold every slot for as long as they keep sending.
        let started = DispatchTime.now().uptimeNanoseconds
        let budgetSeconds = 25.0
        var servedAfterSeconds: Double?
        while Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9 < budgetSeconds {
            if Self.probeHealth(port: port, timeoutSeconds: 2) != nil {
                servedAfterSeconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        for client in clients {
            client.stop()
        }
        server.stop()
        _ = try? await task.value

        #expect(
            servedAfterSeconds != nil,
            """
            a well-behaved client never got a connection slot within \(Int(budgetSeconds))s; \
            trickling clients held every slot because the request head has no overall deadline
            """)
    }
}

#endif
