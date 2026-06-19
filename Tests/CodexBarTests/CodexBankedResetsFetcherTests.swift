import Foundation
import Testing
@testable import CodexBarCore

struct CodexBankedResetsFetcherTests {
    @Test
    func `fetcher sends read only request with CodexBar OAuth headers`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
            #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)
            #expect(request.value(forHTTPHeaderField: "originator") == nil)

            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"credits":[],"available_count":0}"#.utf8), response)
        }

        let snapshot = try await CodexBankedResetsFetcher.fetchBankedResets(
            accessToken: "access-token",
            accountId: "account-123",
            env: [:],
            now: Date(timeIntervalSince1970: 1_700_000_000),
            transport: transport)

        #expect(snapshot.availableCount == 0)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func `fetcher uses configured ChatGPT backend base URL`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://example.test/backend-api/wham/rate-limit-reset-credits")
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(#"{"credits":[],"available_count":0}"#.utf8), response)
        }
        let config = #"chatgpt_base_url = "https://example.test/backend-api""#

        _ = try await CodexBankedResetsFetcher.fetchBankedResets(
            accessToken: "access-token",
            accountId: nil,
            env: [:],
            configContents: config,
            transport: transport)
    }

    @Test
    func `fetcher maps unauthorized response to OAuth unauthorized error`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(#"{"error":{"message":"bad token"}}"#.utf8), response)
        }

        do {
            _ = try await CodexBankedResetsFetcher.fetchBankedResets(
                accessToken: "access-token",
                accountId: nil,
                env: [:],
                transport: transport)
            Issue.record("Expected unauthorized error")
        } catch let error as CodexOAuthFetchError {
            #expect(error.errorDescription == CodexOAuthFetchError.unauthorized.errorDescription)
        } catch {
            Issue.record("Expected CodexOAuthFetchError, got \(error)")
        }
    }
}
