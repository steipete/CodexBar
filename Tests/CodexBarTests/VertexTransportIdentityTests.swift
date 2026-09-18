import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct VertexTransportIdentityTests {
    enum Wrapper: CaseIterable, Sendable {
        case usage
        case refresh

        func wrap(_ error: Error) -> Error {
            switch self {
            case .usage: VertexAIFetchError.networkError(error)
            case .refresh: VertexAITokenRefresher.RefreshError.networkError(error)
            }
        }

        var prefix: String {
            switch self {
            case .usage: "Vertex AI network error: "
            case .refresh: "Network error during token refresh: "
            }
        }
    }

    @Test(arguments: Wrapper.allCases, ProviderTransportRegressionSupport.codes)
    func `owned Vertex wrappers preserve transport policy`(wrapper: Wrapper, code: URLError.Code) {
        let error = wrapper.wrap(ProviderTransportRegressionSupport.urlError(code))
        ProviderTransportRegressionSupport.expectPolicy(
            error, code: code, description: wrapper.prefix + "Verbindung fehlgeschlagen")
        #expect(UsageStore.errorIsCancellation(error) == (code == .cancelled))
    }

    @Test(arguments: Wrapper.allCases)
    func `wrapped Vertex task cancellation stays cancellation`(wrapper: Wrapper) {
        ProviderTransportRegressionSupport.expectPolicy(wrapper.wrap(CancellationError()), code: .cancelled)
        #expect(UsageStore.errorIsCancellation(wrapper.wrap(CancellationError())))
    }

    @Test(arguments: Wrapper.allCases, [URLError.Code.badURL, .secureConnectionFailed])
    func `Vertex transport allowlist stays bounded`(wrapper: Wrapper, code: URLError.Code) {
        let error = wrapper.wrap(ProviderTransportRegressionSupport.urlError(code))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "network_error")
    }

    @Test
    func `Vertex authentication and configuration failures are not transport failures`() {
        let failures: [Error] = [
            VertexAIFetchError.unauthorized, VertexAIFetchError.forbidden, VertexAIFetchError.noProject,
            VertexAIFetchError.noData, VertexAIFetchError.invalidResponse("fixture"),
            VertexAITokenRefresher.RefreshError.expired, VertexAITokenRefresher.RefreshError.revoked,
            VertexAITokenRefresher.RefreshError.invalidResponse("fixture"),
        ]
        for error in failures {
            #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
            #expect(!UsageStore.isStartupConnectivityRetryableError(error))
            #expect(UsageStore.refreshFailureHookStatus(error) == "error")
        }
    }

    @Test(arguments: [true, false])
    func `real Vertex refresh error preserves only existing identity snapshots`(hasPriorData: Bool) async throws {
        let transport = ProviderHTTPTransportStub { _ in throw ProviderTransportRegressionSupport.urlError() }
        let error = await ProviderTransportRegressionSupport.captureFailure {
            _ = try await VertexAITokenRefresher.refresh(Self.credentials(), session: transport)
        }
        #expect(await transport.requests().count == 1)
        guard case let .networkError(underlying) = error as? VertexAITokenRefresher.RefreshError else {
            Issue.record("Expected the existing typed Vertex refresh error")
            return
        }
        #expect((underlying as NSError).code == NSURLErrorCannotFindHost)
        ProviderTransportRegressionSupport.expectPolicy(error, code: .cannotFindHost)
        try await ProviderTransportRegressionSupport.withStore(
            provider: .vertexai,
            hasPriorData: hasPriorData)
        { store, prior in
            var fetches = 0
            store._test_providerFetchOutcomeOverride = { _ in
                fetches += 1
                return ProviderFetchOutcome(result: .failure(error), attempts: [])
            }
            await store.refreshProvider(.vertexai, allowDisabled: true)
            await store.refreshProvider(.vertexai, allowDisabled: true)
            #expect(fetches == 2)
            #expect(store.errors[.vertexai] == error.localizedDescription)
            #expect((store.snapshot(for: .vertexai) != nil) == hasPriorData)
            if hasPriorData {
                #expect(store.snapshot(for: .vertexai)?.primary == nil)
                #expect(store.snapshot(for: .vertexai)?.identity?.accountEmail == prior.identity?.accountEmail)
                #expect(store.snapshot(for: .vertexai)?.updatedAt == prior.updatedAt)
            }
        }
    }

    @Test(arguments: [true, false])
    func `real Vertex transport cancellation never becomes a refresh outage`(hasPriorData: Bool) async throws {
        let transport = ProviderHTTPTransportStub { _ in
            throw ProviderTransportRegressionSupport.urlError(.cancelled)
        }
        let error = await ProviderTransportRegressionSupport.captureFailure {
            _ = try await VertexAITokenRefresher.refresh(Self.credentials(), session: transport)
        }
        #expect(await transport.requests().count == 1)
        try await ProviderTransportRegressionSupport.withStore(
            provider: .vertexai,
            hasPriorData: hasPriorData)
        { store, prior in
            var fetches = 0
            store._test_providerFetchOutcomeOverride = { _ in
                fetches += 1
                return ProviderFetchOutcome(result: .failure(error), attempts: [])
            }
            for _ in 0..<2 {
                await store.refreshProvider(.vertexai)
                #expect(store.errors[.vertexai] == nil)
                #expect((store.failureGates[.vertexai]?.streak ?? 0) == 0)
                #expect(store.snapshot(for: .vertexai)?.updatedAt == (hasPriorData ? prior.updatedAt : nil))
            }
            #expect(fetches == 2)
        }
    }

    @Test
    func `Vertex auth rejection still clears the previous identity snapshot`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil))
            return (Data(#"{"error":"invalid_grant"}"#.utf8), response)
        }
        let error = await ProviderTransportRegressionSupport.captureFailure {
            _ = try await VertexAITokenRefresher.refresh(Self.credentials(), session: transport)
        }
        try await ProviderTransportRegressionSupport.withStore(provider: .vertexai) { store, _ in
            store
                ._test_providerFetchOutcomeOverride = { _ in
                    ProviderFetchOutcome(result: .failure(error), attempts: [])
                }
            await store.refreshProvider(.vertexai, allowDisabled: true)
            await store.refreshProvider(.vertexai, allowDisabled: true)
            #expect(store.snapshot(for: .vertexai) == nil)
        }
    }

    private static func credentials() -> VertexAIOAuthCredentials {
        VertexAIOAuthCredentials(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            clientId: "fixture-client",
            clientSecret: "fixture-secret",
            projectId: "fixture-project",
            email: "fixture@example.test",
            expiryDate: Date(timeIntervalSince1970: 0))
    }
}
