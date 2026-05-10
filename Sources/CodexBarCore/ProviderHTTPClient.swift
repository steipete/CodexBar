import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class ProviderHTTPClient: @unchecked Sendable {
    public static let shared = ProviderHTTPClient()

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession.shared
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.session.data(for: request)
    }
}
