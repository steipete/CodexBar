import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private let requestReadTimeoutMilliseconds: Int32 = 5000

/// Host header values a `CLILocalHTTPServer` accepts. Loopback names are always allowed;
/// non-loopback bind hosts extend the set instead of replacing the loopback check.
enum CLILocalHTTPAllowedHosts: Equatable, Sendable {
    /// Only loopback names (`127.0.0.1`, `localhost`, `[::1]`).
    case loopbackOnly
    /// Loopback names plus the given lowercased host names (without port).
    case loopbackAnd(Set<String>)
    /// Any syntactically valid host, for wildcard binds such as `0.0.0.0`.
    case any
}

struct CLILocalHTTPRequest {
    let method: String
    let target: String
    let host: String
    let path: String
    let queryItems: [String: String]
    let authorization: String?

    static func parse(
        _ data: Data,
        allowedHosts: CLILocalHTTPAllowedHosts = .loopbackOnly)
        -> Result<CLILocalHTTPRequest, CLILocalHTTPRequestParseError>
    {
        guard let raw = String(data: data, encoding: .utf8),
              let firstLine = raw.components(separatedBy: "\r\n").first
        else {
            return .failure(.invalidRequest)
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 3 else { return .failure(.invalidRequest) }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return .failure(.invalidRequest) }

        let headerResult = Self.parseHeaders(raw)
        let host: String
        let authorization: String?
        switch headerResult {
        case let .success(headers):
            let hosts = headers.compactMap { name, value in
                name.lowercased() == "host" ? value : nil
            }
            guard let candidate = hosts.first else { return .failure(.missingHost) }
            guard hosts.count == 1 else { return .failure(.duplicateHost) }
            guard Self.isAllowedHost(candidate, allowedHosts: allowedHosts) else { return .failure(.disallowedHost) }
            host = candidate

            let authorizations = headers.compactMap { name, value in
                name.lowercased() == "authorization" ? value : nil
            }
            guard authorizations.count <= 1 else { return .failure(.duplicateAuthorization) }
            authorization = authorizations.first
        case let .failure(error):
            return .failure(error)
        }

        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? target
        var queryItems: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                queryItems[item.name] = value
            }
        }

        return .success(CLILocalHTTPRequest(
            method: method,
            target: target,
            host: host,
            path: path,
            queryItems: queryItems,
            authorization: authorization))
    }

    private static func parseHeaders(_ raw: String) -> Result<[(String, String)], CLILocalHTTPRequestParseError> {
        let lines = raw.components(separatedBy: "\r\n")
        var headers: [(String, String)] = []

        for line in lines.dropFirst() {
            if line.isEmpty {
                break
            }
            guard let separator = line.firstIndex(of: ":") else {
                return .failure(.invalidRequest)
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure(.invalidRequest) }
            headers.append((name, value))
        }

        return .success(headers)
    }

    private static func isAllowedHost(_ host: String, allowedHosts: CLILocalHTTPAllowedHosts) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(",") else { return false }

        let hostWithoutPort: String
        if trimmed.hasPrefix("[") {
            guard let closingBracket = trimmed.firstIndex(of: "]") else { return false }
            hostWithoutPort = String(trimmed[...closingBracket])
            let remainder = trimmed[trimmed.index(after: closingBracket)...]
            guard remainder.isEmpty || Self.isValidPortSuffix(String(remainder)) else { return false }
        } else {
            let segments = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            switch segments.count {
            case 1:
                hostWithoutPort = String(segments[0])
            case 2:
                guard Self.isValidPort(String(segments[1])) else { return false }
                hostWithoutPort = String(segments[0])
            default:
                return false
            }
        }

        switch hostWithoutPort.lowercased() {
        case "127.0.0.1", "localhost", "localhost.", "[::1]":
            return true
        default:
            switch allowedHosts {
            case .loopbackOnly:
                return false
            case let .loopbackAnd(hosts):
                return hosts.contains(hostWithoutPort.lowercased())
            case .any:
                return true
            }
        }
    }

    private static func isValidPortSuffix(_ raw: String) -> Bool {
        guard raw.hasPrefix(":") else { return false }
        return self.isValidPort(String(raw.dropFirst()))
    }

    private static func isValidPort(_ raw: String) -> Bool {
        guard let port = Int(raw), port > 0, port <= Int(UInt16.max) else { return false }
        return true
    }
}

enum CLILocalHTTPRequestParseError: Error, Equatable {
    case invalidRequest
    case missingHost
    case duplicateHost
    case disallowedHost
    case duplicateAuthorization
}

enum CLIHTTPStatus {
    case ok
    case badRequest
    case unauthorized
    case forbidden
    case notFound
    case methodNotAllowed
    case internalServerError
    case gatewayTimeout
    var code: Int {
        switch self {
        case .ok: 200
        case .badRequest: 400
        case .unauthorized: 401
        case .forbidden: 403
        case .notFound: 404
        case .methodNotAllowed: 405
        case .internalServerError: 500
        case .gatewayTimeout: 504
        }
    }

    var reason: String {
        switch self {
        case .ok: "OK"
        case .badRequest: "Bad Request"
        case .unauthorized: "Unauthorized"
        case .forbidden: "Forbidden"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .internalServerError: "Internal Server Error"
        case .gatewayTimeout: "Gateway Timeout"
        }
    }
}

struct CLILocalHTTPResponse {
    let status: CLIHTTPStatus
    let body: Data
    let contentType: String
    let extraHeaders: [(String, String)]
    let usageCacheKeys: [String?]?

    init(
        status: CLIHTTPStatus,
        body: Data,
        contentType: String = "application/json; charset=utf-8",
        extraHeaders: [(String, String)] = [],
        usageCacheKeys: [String?]? = nil)
    {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.extraHeaders = extraHeaders
        self.usageCacheKeys = usageCacheKeys
    }

    var serialized: Data {
        var headers = "HTTP/1.1 \(self.status.code) \(self.status.reason)\r\n"
        headers += "Content-Type: \(self.contentType)\r\n"
        headers += "Content-Length: \(self.body.count)\r\n"
        headers += "Connection: close\r\n"
        for (name, value) in self.extraHeaders {
            headers += "\(name): \(value)\r\n"
        }
        headers += "\r\n"

        var data = Data(headers.utf8)
        data.append(self.body)
        return data
    }
}

/// Hard cap on accepted connections. Acquisition happens before spawning the
/// per-client task, so slow or partial pre-auth requests cannot create an
/// unbounded task or file-descriptor population.
final class CLILocalHTTPConnectionGate: @unchecked Sendable {
    private let maximumConnections: Int
    private let lock = NSLock()
    private var activeConnections = 0

    init(maximumConnections: Int) {
        precondition(maximumConnections > 0)
        self.maximumConnections = maximumConnections
    }

    func tryAcquire() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.activeConnections < self.maximumConnections else { return false }
        self.activeConnections += 1
        return true
    }

    func release() {
        self.lock.lock()
        defer { self.lock.unlock() }
        precondition(self.activeConnections > 0)
        self.activeConnections -= 1
    }

    var activeCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.activeConnections
    }
}

final class CLILocalHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (CLILocalHTTPRequest) async -> CLILocalHTTPResponse

    private let host: String
    private let port: UInt16
    private let allowedHosts: CLILocalHTTPAllowedHosts
    private let connectionGate: CLILocalHTTPConnectionGate
    private let handler: Handler
    private let stateLock = NSLock()
    private var listeningFD: Int32?
    private var boundPort: UInt16?
    private var stopRequested = false

    init(
        host: String,
        port: UInt16,
        allowedHosts: CLILocalHTTPAllowedHosts = .loopbackOnly,
        maximumConnections: Int = 16,
        handler: @escaping Handler)
    {
        self.host = host
        self.port = port
        self.allowedHosts = allowedHosts
        self.connectionGate = CLILocalHTTPConnectionGate(maximumConnections: maximumConnections)
        self.handler = handler
    }

    /// The port the listening socket is bound to, once `run` is accepting connections.
    /// Resolves ephemeral (`0`) port requests to the kernel-assigned port.
    var listeningPort: UInt16? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.boundPort
    }

    func stop() {
        self.stateLock.lock()
        self.stopRequested = true
        self.stateLock.unlock()
    }

    func run(onListening: @Sendable () -> Void = {}) async throws {
        ignoreSIGPIPE()

        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #elseif canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #elseif canImport(Musl)
        let streamType = Int32(SOCK_STREAM)
        #endif

        let serverFD = socket(AF_INET, streamType, 0)
        guard serverFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var ownsServerFD = true
        defer {
            if ownsServerFD {
                closeSocket(serverFD)
            }
        }

        var reuse: Int32 = 1
        setsockopt(
            serverFD,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = self.port.bigEndian
        guard inet_pton(AF_INET, self.host, &address.sin_addr) == 1 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(serverFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard listen(serverFD, 16) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard self.installListeningFD(serverFD, port: Self.resolvedPort(of: serverFD) ?? self.port) else {
            return
        }
        ownsServerFD = false
        defer {
            if self.releaseListeningFD(serverFD) {
                closeSocket(serverFD)
            }
        }
        onListening()

        while !self.isStopRequested {
            guard waitForReadable(serverFD, timeoutMilliseconds: 250) else {
                continue
            }
            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(serverFD, &clientAddress, &clientLength)
            guard clientFD >= 0 else {
                if self.isStopRequested {
                    return
                }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNABORTED {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard self.connectionGate.tryAcquire() else {
                closeSocket(clientFD)
                continue
            }
            let handler = self.handler
            let allowedHosts = self.allowedHosts
            let connectionGate = self.connectionGate
            Task {
                defer {
                    closeSocket(clientFD)
                    connectionGate.release()
                }
                await handleClient(clientFD, allowedHosts: allowedHosts, handler: handler)
            }
        }
    }

    private var isStopRequested: Bool {
        self.stateLock.lock()
        let value = self.stopRequested
        self.stateLock.unlock()
        return value
    }

    private func installListeningFD(_ fd: Int32, port: UInt16) -> Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        guard !self.stopRequested else { return false }
        self.listeningFD = fd
        self.boundPort = port
        return true
    }

    private static func resolvedPort(of fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard result == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    private func releaseListeningFD(_ fd: Int32) -> Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        guard self.listeningFD == fd else { return false }
        self.listeningFD = nil
        return true
    }
}

private func handleClient(
    _ clientFD: Int32,
    allowedHosts: CLILocalHTTPAllowedHosts,
    handler: @Sendable (CLILocalHTTPRequest) async -> CLILocalHTTPResponse) async
{
    let request: CLILocalHTTPRequest
    switch readRequest(clientFD, allowedHosts: allowedHosts) {
    case let .success(parsedRequest):
        request = parsedRequest
    case .failure(.disallowedHost):
        sendResponse(
            CLILocalHTTPResponse(
                status: .forbidden,
                body: Data(#"{"error":"forbidden host"}"#.utf8),
                extraHeaders: [("Cache-Control", "no-store")]),
            to: clientFD)
        return
    case .failure:
        sendResponse(
            CLILocalHTTPResponse(
                status: .badRequest,
                body: Data(#"{"error":"invalid request"}"#.utf8),
                extraHeaders: [("Cache-Control", "no-store")]),
            to: clientFD)
        return
    }

    let response = await handler(request)
    sendResponse(response, to: clientFD)
}

private func readRequest(
    _ fd: Int32,
    allowedHosts: CLILocalHTTPAllowedHosts) -> Result<CLILocalHTTPRequest, CLILocalHTTPRequestParseError>
{
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let bufferSize = buffer.count
    var sawHeaderEnd = false

    while data.count < 16384 {
        guard waitForReadable(fd, timeoutMilliseconds: requestReadTimeoutMilliseconds) else {
            return .failure(.invalidRequest)
        }
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            recv(fd, rawBuffer.baseAddress, bufferSize, 0)
        }
        guard count > 0 else { break }
        data.append(buffer, count: count)
        if data.range(of: Data("\r\n\r\n".utf8)) != nil {
            sawHeaderEnd = true
            break
        }
    }

    guard sawHeaderEnd else { return .failure(.invalidRequest) }
    return CLILocalHTTPRequest.parse(data, allowedHosts: allowedHosts)
}

private func sendResponse(_ response: CLILocalHTTPResponse, to fd: Int32) {
    let data = response.serialized
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = send(fd, base.advanced(by: sent), data.count - sent, sendNoSignalFlags())
            guard count > 0 else { break }
            sent += count
        }
    }
}

private func waitForReadable(_ fd: Int32, timeoutMilliseconds: Int32) -> Bool {
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        let result = poll(&pollFD, 1, timeoutMilliseconds)
        if result > 0 {
            return (pollFD.revents & Int16(POLLIN)) != 0
        }
        if result == -1, errno == EINTR {
            continue
        }
        return false
    }
}

private func sendNoSignalFlags() -> Int32 {
    #if canImport(Darwin)
    0
    #else
    Int32(MSG_NOSIGNAL)
    #endif
}

private func ignoreSIGPIPE() {
    #if canImport(Darwin)
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
    #elseif canImport(Glibc)
    _ = Glibc.signal(SIGPIPE, SIG_IGN)
    #elseif canImport(Musl)
    _ = Musl.signal(SIGPIPE, SIG_IGN)
    #endif
}

private func closeSocket(_ fd: Int32) {
    #if canImport(Darwin)
    Darwin.close(fd)
    #elseif canImport(Glibc)
    Glibc.close(fd)
    #elseif canImport(Musl)
    Musl.close(fd)
    #endif
}
