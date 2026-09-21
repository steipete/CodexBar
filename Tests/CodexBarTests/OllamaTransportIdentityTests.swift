import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct OllamaTransportIdentityTests {
    enum Route: CaseIterable, Sendable {
        case validation
        case tags
    }

    @Test(arguments: Route.allCases, ProviderTransportRegressionSupport.codes)
    func `Ollama API requests preserve localized transport errors`(route: Route, code: URLError.Code) async {
        let (error, transport) = await Self.failure(
            route: route,
            error: ProviderTransportRegressionSupport.urlError(code))
        ProviderTransportRegressionSupport.expectPolicy(error, code: code)
        if code != .cancelled {
            #expect(error.localizedDescription == "Ollama request failed: Verbindung fehlgeschlagen")
            #expect((error as NSError).userInfo["fixture-marker"] as? String == "preserved")
        }
        #expect(await transport.requests().count == (route == .validation ? 1 : 2))
    }

    @Test(arguments: Route.allCases, [URLError.Code.badURL, .secureConnectionFailed])
    func `Ollama API keeps nonpreservable URL failures bounded`(route: Route, code: URLError.Code) async {
        let (error, _) = await Self.failure(route: route, error: ProviderTransportRegressionSupport.urlError(code))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "network_error")
    }

    @Test(arguments: Route.allCases)
    func `Ollama task cancellation never becomes a connectivity retry`(route: Route) async {
        let (error, _) = await Self.failure(route: route, error: CancellationError())
        #expect(error is CancellationError)
        ProviderTransportRegressionSupport.expectPolicy(error, code: .cancelled)
    }

    @Test(arguments: Route.allCases, [true, false])
    func `ordinary Ollama API outage preserves only an existing API identity`(
        route: Route,
        hasPriorData: Bool) async throws
    {
        let (error, _) = await Self.failure(route: route, error: ProviderTransportRegressionSupport.urlError())
        try await ProviderTransportRegressionSupport.withStore(
            provider: .ollama,
            hasPriorData: hasPriorData)
        { store, prior in
            var fetches = 0
            store._test_providerFetchOutcomeOverride = { _ in
                fetches += 1
                return ProviderFetchOutcome(result: .failure(error), attempts: [])
            }
            await store.refreshProvider(.ollama, allowDisabled: true)
            await store.refreshProvider(.ollama, allowDisabled: true)
            #expect(fetches == 2)
            #expect(store.errors[.ollama] == error.localizedDescription)
            #expect((store.snapshot(for: .ollama) != nil) == hasPriorData)
            if hasPriorData {
                #expect(store.snapshot(for: .ollama)?.primary == nil)
                #expect(store.snapshot(for: .ollama)?.identity?.loginMethod == "API key")
                #expect(store.snapshot(for: .ollama)?.updatedAt == prior.updatedAt)
            }
        }
    }

    @Test(arguments: [401, 503])
    func `Ollama HTTP rejection does not acquire transport retention`(statusCode: Int) async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
            return (Data("{}".utf8), response)
        }
        let error = await ProviderTransportRegressionSupport.captureFailure {
            _ = try await OllamaAPIUsageFetcher.fetchUsage(apiKey: "fixture-key", transport: transport)
        }
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        try await ProviderTransportRegressionSupport.withStore(provider: .ollama) { store, _ in
            store
                ._test_providerFetchOutcomeOverride = { _ in
                    ProviderFetchOutcome(result: .failure(error), attempts: [])
                }
            await store.refreshProvider(.ollama, allowDisabled: true)
            await store.refreshProvider(.ollama, allowDisabled: true)
            #expect(store.snapshot(for: .ollama) == nil)
        }
    }

    @Test
    func `Ollama does not unwrap arbitrary underlying NSError metadata`() async {
        let original = NSError(domain: "fixture-provider", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Fixture failure",
            NSUnderlyingErrorKey: ProviderTransportRegressionSupport.urlError(),
        ])
        let (error, _) = await Self.failure(route: .validation, error: original)
        #expect(error.localizedDescription == "Ollama request failed: Fixture failure")
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "error")
    }

    private static func failure(route: Route, error: Error) async -> (Error, ProviderHTTPTransportStub) {
        let transport = ProviderHTTPTransportStub { request in
            if route == .tags, request.url?.path == "/api/web_search" {
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 400, httpVersion: nil, headerFields: nil))
                return (Data("{}".utf8), response)
            }
            throw error
        }
        let failure = await ProviderTransportRegressionSupport.captureFailure {
            _ = try await OllamaAPIUsageFetcher.fetchUsage(apiKey: "fixture-key", transport: transport)
        }
        return (failure, transport)
    }
}
