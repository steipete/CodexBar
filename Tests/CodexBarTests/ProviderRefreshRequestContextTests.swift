import Foundation
import Testing
@testable import CodexBarCore

struct ProviderRefreshRequestContextTests {
    @Test
    func `new request stays bound for the full awaited operation`() async throws {
        #expect(ProviderRefreshRequestContext.id == nil)

        let firstRequestID = try await ProviderRefreshRequestContext.withNewRequest {
            let requestID = try #require(ProviderRefreshRequestContext.id)
            await Task.yield()
            #expect(ProviderRefreshRequestContext.id == requestID)
            return requestID
        }

        let secondRequestID = await ProviderRefreshRequestContext.withNewRequest {
            ProviderRefreshRequestContext.id
        }
        #expect(secondRequestID != nil)
        #expect(secondRequestID != firstRequestID)
        #expect(ProviderRefreshRequestContext.id == nil)
    }
}
