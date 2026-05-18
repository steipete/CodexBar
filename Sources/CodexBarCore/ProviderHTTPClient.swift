import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

@preconcurrency public protocol ProviderHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct ProviderHTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse

    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }

    public var statusCode: Int {
        self.response.statusCode
    }
}

extension URLSession {
    public func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        let (data, response) = try await self.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProviderHTTPResponse(data: data, response: httpResponse)
    }
}

extension URLSession: ProviderHTTPTransport {}

public struct ProviderHTTPTransportHandler: ProviderHTTPTransport, Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.handler(request)
    }
}

extension ProviderHTTPTransport {
    public func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        let (data, response) = try await self.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProviderHTTPResponse(data: data, response: httpResponse)
    }
}

public final class ProviderHTTPClient: ProviderHTTPTransport, @unchecked Sendable {
    public static let shared = ProviderHTTPClient(session: ProviderHTTPClient.sharedSession())

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.defaultConfiguration())
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        return configuration
    }

    private static func sharedSession() -> URLSession {
        if self.isRunningTests {
            // XCTest URLProtocol.registerClass stubs only intercept URLSession.shared on macOS.
            return .shared
        }
        return URLSession(configuration: self.defaultConfiguration())
    }

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        if ProcessInfo.processInfo.processName.lowercased().contains("xctest") {
            return true
        }
        return CommandLine.arguments.contains { $0.lowercased().contains(".xctest") }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.session.data(for: request)
    }
}
