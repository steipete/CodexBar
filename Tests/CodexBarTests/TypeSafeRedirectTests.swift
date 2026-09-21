#if os(macOS)
import Foundation
import Network
import Testing
@testable import CodexBarCore

struct TypeSafeRedirectTests {
    @Test(arguments: [302, 307], [false, true])
    func `selected cookies never reach same or cross origin redirect destinations`(
        status: Int, crossOrigin: Bool) async throws
    {
        let server = try TypeSafeRedirectServer(status: status, crossOrigin: crossOrigin)
        let port = try await server.start()
        defer { server.stop() }
        let configuration = TypeSafeWebFetchStrategy.makeConfiguration()
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration, delegate: TypeSafeRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = try URLRequest(url: #require(URL(string: "http://127.0.0.1:\(port)/settings/billing")))
        request.setValue("session=synthetic-billing-cookie", forHTTPHeaderField: "Cookie")
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == status)
        let requests = server.requests.value
        #expect(requests.count == 1)
        #expect(requests.first?.hasPrefix("GET /settings/billing ") == true)
        #expect(requests.first?.contains("session=synthetic-billing-cookie") == true)
    }
}

private final class TypeSafeRedirectServer: @unchecked Sendable {
    let requests = LockIsolated<[String]>([])
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TypeSafeRedirectProof")
    private let status: Int
    private let crossOrigin: Bool

    init(status: Int, crossOrigin: Bool) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
        self.status = status
        self.crossOrigin = crossOrigin
    }

    func start() async throws -> UInt16 {
        self.listener.newConnectionHandler = { [self] connection in
            let host = self.crossOrigin ? "localhost" : "127.0.0.1"
            let location = "http://\(host):\(self.listener.port!.rawValue)/capture"
            TypeSafeRedirectConnection(
                connection: connection,
                requests: self.requests,
                response: "HTTP/1.1 \(self.status) Redirect\r\nLocation: \(location)\r\n" +
                    "Content-Length: 0\r\nConnection: close\r\n\r\n").start(queue: self.queue)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case let .failed(error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() { self.listener.cancel() }
}

private final class TypeSafeRedirectConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let requests: LockIsolated<[String]>
    private let response: String
    private var buffer = Data()

    init(connection: NWConnection, requests: LockIsolated<[String]>, response: String) {
        self.connection = connection
        self.requests = requests
        self.response = response
    }

    func start(queue: DispatchQueue) {
        self.connection.start(queue: queue)
        self.receive()
    }

    private func receive() {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            if let data { self.buffer.append(data) }
            guard error == nil, self.buffer.count <= 8192 else { self.connection.cancel(); return }
            guard let request = String(data: self.buffer, encoding: .utf8) else {
                self.connection.cancel()
                return
            }
            guard request.contains("\r\n\r\n") else {
                if complete { self.connection.cancel() } else { self.receive() }
                return
            }
            self.requests.setValue(self.requests.value + [request])
            let reply = request.hasPrefix("GET /settings/billing ")
                ? self.response : "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            self.connection.send(content: Data(reply.utf8), completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
#endif
