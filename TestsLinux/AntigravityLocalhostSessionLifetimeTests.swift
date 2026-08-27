import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import CodexBarCore

/// Covers the process-lifetime session-reuse contract from the #2243 mitigation,
/// without establishing the root cause of Linux FoundationNetworking/libdispatch crashes.
struct AntigravityLocalhostSessionLifetimeTests {
    @Test
    func `localhost requests reuse one session and delegate`() {
        let first = AntigravityStatusProbe.localhostSessionForTesting
        let second = AntigravityStatusProbe.localhostSessionForTesting

        #expect(first === second)
        #expect(first.delegate is LocalhostSessionDelegate)
    }

    @Test
    func `concurrent requests to a closed localhost port all throw without teardown churn`() async throws {
        try await Self.withClosedLoopbackPort { port in
            let thrownCount = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<32 {
                    group.addTask {
                        do {
                            _ = try await AntigravityStatusProbe.makeRequest(
                                payload: AntigravityStatusProbe.RequestPayload(path: "/closed", body: [:]),
                                context: AntigravityStatusProbe.RequestContext(
                                    endpoints: [
                                        AntigravityStatusProbe.AntigravityConnectionEndpoint(
                                            scheme: "http",
                                            port: port,
                                            csrfToken: "",
                                            source: .languageServer),
                                    ],
                                    timeout: 0.5))
                            return false
                        } catch {
                            return true
                        }
                    }
                }

                var count = 0
                for await didThrow in group where didThrow {
                    count += 1
                }
                return count
            }

            #expect(thrownCount == 32)
        }
    }

    /// Keeps an ephemeral loopback socket bound but not listening until requests finish,
    /// preventing another process from reusing the port while connections are refused.
    private static func withClosedLoopbackPort(_ operation: (Int) async -> Void) async throws {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fileDescriptor = socket(AF_INET, streamType, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fileDescriptor) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fileDescriptor, socketAddress, &addressLength)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        await operation(Int(UInt16(bigEndian: address.sin_port)))
    }
}
