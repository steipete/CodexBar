import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol ProviderHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ProviderHTTPTransport {}

public final class ProviderHTTPClient: ProviderHTTPTransport, @unchecked Sendable {
    public static let shared = ProviderHTTPClient()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.session.data(for: request)
    }
}
