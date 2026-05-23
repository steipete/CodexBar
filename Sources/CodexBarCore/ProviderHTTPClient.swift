import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol ProviderHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

#if !os(Linux)
extension URLSession: ProviderHTTPTransport {}
#endif

extension URLSession {
    public func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        let (data, response) = try await self.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProviderHTTPResponse(data: data, response: httpResponse)
    }
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

public struct ProviderHTTPRetryPolicy: Sendable {
    public let maxRetries: Int
    public let retryableStatusCodes: Set<Int>
    public let retryableURLErrorCodes: Set<URLError.Code>
    public let retryableMethods: Set<String>
    public let baseDelaySeconds: TimeInterval
    public let maxDelaySeconds: TimeInterval

    public init(
        maxRetries: Int,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        retryableURLErrorCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
        ],
        retryableMethods: Set<String> = ["GET", "HEAD", "OPTIONS"],
        baseDelaySeconds: TimeInterval = 1,
        maxDelaySeconds: TimeInterval = 10)
    {
        self.maxRetries = max(0, maxRetries)
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
        self.retryableMethods = retryableMethods
        self.baseDelaySeconds = max(0, baseDelaySeconds)
        self.maxDelaySeconds = max(0, maxDelaySeconds)
    }

    public static let disabled = ProviderHTTPRetryPolicy(
        maxRetries: 0,
        retryableStatusCodes: [],
        retryableURLErrorCodes: [],
        baseDelaySeconds: 0,
        maxDelaySeconds: 0)

    public static let transientIdempotent = ProviderHTTPRetryPolicy(maxRetries: 1)

    func shouldRetry(request: URLRequest, attempt: Int, statusCode: Int) -> Bool {
        self.canRetry(request: request, attempt: attempt)
            && self.retryableStatusCodes.contains(statusCode)
    }

    func shouldRetry(request: URLRequest, attempt: Int, error: Error) -> Bool {
        guard self.canRetry(request: request, attempt: attempt) else { return false }
        guard let urlError = error as? URLError else { return false }
        return self.retryableURLErrorCodes.contains(urlError.code)
    }

    func delaySeconds(attempt: Int, response: HTTPURLResponse?) -> TimeInterval {
        if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds >= 0
        {
            return min(seconds, self.maxDelaySeconds)
        }

        guard self.baseDelaySeconds > 0 else { return 0 }
        let multiplier = pow(2, Double(max(0, attempt)))
        return min(self.baseDelaySeconds * multiplier, self.maxDelaySeconds)
    }

    private func canRetry(request: URLRequest, attempt: Int) -> Bool {
        guard attempt < self.maxRetries else { return false }
        let method = request.httpMethod?.uppercased() ?? "GET"
        return self.retryableMethods.contains(method)
    }
}

public struct ProviderHTTPTransportHandler: ProviderHTTPTransport {
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
        try await self.response(for: request, retryPolicy: .disabled)
    }

    public func response(
        for request: URLRequest,
        retryPolicy: ProviderHTTPRetryPolicy) async throws -> ProviderHTTPResponse
    {
        var attempt = 0

        while true {
            do {
                let (data, response) = try await self.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                let providerResponse = ProviderHTTPResponse(data: data, response: httpResponse)
                guard retryPolicy.shouldRetry(
                    request: request,
                    attempt: attempt,
                    statusCode: providerResponse.statusCode)
                else {
                    return providerResponse
                }
                try await Self.sleepBeforeRetry(policy: retryPolicy, attempt: attempt, response: httpResponse)
                attempt += 1
            } catch {
                guard retryPolicy.shouldRetry(request: request, attempt: attempt, error: error) else {
                    throw error
                }
                try await Self.sleepBeforeRetry(policy: retryPolicy, attempt: attempt, response: nil)
                attempt += 1
            }
        }
    }

    private static func sleepBeforeRetry(
        policy: ProviderHTTPRetryPolicy,
        attempt: Int,
        response: HTTPURLResponse?) async throws
    {
        let delay = policy.delaySeconds(attempt: attempt, response: response)
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
