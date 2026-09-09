import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Deterministic overlap primitives: callers suspend on gates and transports instead of relying
/// on timing or sleeps, so the actor-reentrancy race is exercised on every run.
actor AsyncTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if self.opened { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        self.opened = true
        for continuation in self.waiters {
            continuation.resume()
        }
        self.waiters = []
    }
}

actor AsyncArrivalCounter {
    private(set) var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    @discardableResult
    func arrive() -> Int {
        self.count += 1
        self.resumeSatisfied()
        return self.count
    }

    func waitForCount(_ target: Int) async {
        if self.count >= target { return }
        await withCheckedContinuation { continuation in
            self.waiters.append((target, continuation))
        }
    }

    private func resumeSatisfied() {
        for index in self.waiters.indices.reversed() where self.count >= self.waiters[index].target {
            self.waiters.remove(at: index).continuation.resume()
        }
    }
}

actor AsyncPhaseFlag {
    private var active = true

    func deactivate() {
        self.active = false
    }

    func isActive() -> Bool {
        self.active
    }
}

private func concurrencyIdentityResponse(
    _ body: String,
    statusCode: Int = 200) throws -> (Data, URLResponse)
{
    let response = try #require(HTTPURLResponse(
        url: HuggingFaceIdentityService.whoamiURL,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]))
    return (Data(body.utf8), response)
}

private func concurrencyHTMLResponse(
    url: URL,
    body: String,
    statusCode: Int = 200) throws -> (Data, URLResponse)
{
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/html; charset=utf-8"]))
    return (Data(body.utf8), response)
}

private func concurrencyDataProps(_ json: String) -> String {
    let encoded = json
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
    return #"<div class="billing" data-props="\#(encoded)"></div>"#
}

private struct HuggingFaceConcurrencyTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        ""
    }

    func detectVersion() -> String? {
        nil
    }
}

private func concurrencyFetchContext() -> ProviderFetchContext {
    let environment = [HuggingFaceSettingsReader.tokenPathEnvironmentKey: FileManager.default.temporaryDirectory
        .appendingPathComponent("HuggingFaceSingleFlight-no-token-\(UUID().uuidString)").path]
    return ProviderFetchContext(
        runtime: .app,
        sourceMode: .auto,
        includeCredits: false,
        includeOptionalUsage: true,
        webTimeout: 1,
        webDebugDumpHTML: false,
        verbose: false,
        env: environment,
        settings: ProviderSettingsSnapshot.make(huggingface: HuggingFaceProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "session=fixture")),
        fetcher: UsageFetcher(environment: environment),
        claudeFetcher: HuggingFaceConcurrencyTestClaudeFetcher(),
        browserDetection: BrowserDetection(cacheTTL: 0))
}

struct HuggingFaceSingleFlightConcurrencyTests {
    private static let userBody = #"{"type":"user","id":"opaque-id-1","name":"fixture-user"}"#

    @Test
    func `simultaneous batch scope callers share one blocked observation fetch`() async throws {
        let arrivals = AsyncArrivalCounter()
        let start = AsyncTestGate()
        let release = AsyncTestGate()
        let scope = HuggingFaceWalletBatchScope()
        let context = concurrencyFetchContext()
        let fetcher: HuggingFaceWalletBatchScope.ObservationFetcher = { _ in
            _ = await arrivals.arrive()
            await release.wait()
            return HuggingFaceBrowserWalletObservation(
                wallet: HuggingFaceWalletSnapshot(
                    balanceUSD: 9.25,
                    observedAt: Date(timeIntervalSince1970: 1_777_000_000)),
                identity: nil)
        }

        var tasks: [Task<HuggingFaceBrowserWalletObservation, any Error>] = [
            Task { try await scope.observation(for: context, fetcher: fetcher) },
        ]
        for _ in 1..<4 {
            tasks.append(Task {
                await start.wait()
                return try await scope.observation(for: context, fetcher: fetcher)
            })
        }

        // The first caller is provably inside the blocked fetch before the others start, so the
        // remaining callers overlap the in-flight operation instead of following it.
        await arrivals.waitForCount(1)
        await start.open()
        await release.open()

        var observations: [HuggingFaceBrowserWalletObservation] = []
        for task in tasks {
            try await observations.append(task.value)
        }

        #expect(observations.map(\.wallet.balanceUSD) == Array(repeating: 9.25, count: 4))
        #expect(await arrivals.count == 1)

        // Completed success stays memoized for the rest of the batch.
        let memoized = try await scope.observation(for: context, fetcher: fetcher)
        #expect(memoized.wallet.balanceUSD == 9.25)
        #expect(await arrivals.count == 1)
    }

    @Test
    func `one shared batch observation causes one billing request and one browser identity request`() async throws {
        let arrivals = AsyncArrivalCounter()
        let start = AsyncTestGate()
        let release = AsyncTestGate()

        let webTransport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://huggingface.co/settings/billing")
            _ = await arrivals.arrive()
            await release.wait()
            let payload = #"{"entity":{"type":"user","name":"unverified-name","currentBalanceUsd":9.25}}"#
            return try concurrencyHTMLResponse(
                url: url,
                body: concurrencyDataProps(payload))
        }
        let identityTransport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/whoami-v2")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            return try concurrencyIdentityResponse(
                #"{"type":"user","id":"browser-opaque-id","name":"browser-user"}"#)
        }
        let webStrategy = HuggingFaceWebFetchStrategy(
            transport: webTransport,
            resolveCookieHeader: { _ in "session=fixture" })
        let fetcher = webStrategy.makeObservationFetcher(
            identityService: HuggingFaceIdentityService(transport: identityTransport))
        let scope = HuggingFaceWalletBatchScope()
        let context = concurrencyFetchContext()

        var tasks: [Task<HuggingFaceBrowserWalletObservation, any Error>] = [
            Task { try await scope.observation(for: context, fetcher: fetcher) },
        ]
        for _ in 1..<4 {
            tasks.append(Task {
                await start.wait()
                return try await scope.observation(for: context, fetcher: fetcher)
            })
        }
        await arrivals.waitForCount(1)
        await start.open()
        await release.open()

        var observations: [HuggingFaceBrowserWalletObservation] = []
        for task in tasks {
            try await observations.append(task.value)
        }

        #expect(observations.map(\.wallet.balanceUSD) == Array(repeating: 9.25, count: 4))
        #expect(await arrivals.count == 1)
        #expect(await webTransport.requests().count == 1)
        #expect(await identityTransport.requests().count == 1)
    }

    @Test
    func `simultaneous identity lookups for one credential share a single whoami request`() async throws {
        let arrivals = AsyncArrivalCounter()
        let start = AsyncTestGate()
        let release = AsyncTestGate()
        let transport = ProviderHTTPTransportStub { _ in
            _ = await arrivals.arrive()
            await release.wait()
            return try concurrencyIdentityResponse(Self.userBody)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        var tasks: [Task<HuggingFaceIdentity?, any Error>] = [
            Task { try await service.identity(bearerToken: "hf_fixture_token", timeout: 1) },
        ]
        for _ in 1..<4 {
            tasks.append(Task {
                await start.wait()
                return try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
            })
        }
        await arrivals.waitForCount(1)
        await start.open()
        await release.open()

        var identities: [HuggingFaceIdentity?] = []
        for task in tasks {
            try await identities.append(task.value)
        }

        #expect(identities.compactMap { $0?.opaqueUserID } == Array(repeating: "opaque-id-1", count: 4))
        #expect(await arrivals.count == 1)
        #expect(await transport.requests().count == 1)

        // A successful concurrent lookup populates the normal 12h cache.
        let cached = try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
        #expect(cached?.opaqueUserID == "opaque-id-1")
        #expect(await transport.requests().count == 1)
        #expect(await service.cacheCount() == 1)
    }

    @Test
    func `simultaneous identity lookups for different credentials stay independent`() async throws {
        let release = AsyncTestGate()
        let transport = ProviderHTTPTransportStub { request in
            let isBearer = request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
            await release.wait()
            let body = isBearer
                ? #"{"type":"user","id":"bearer-opaque","name":"bearer-user"}"#
                : #"{"type":"user","id":"cookie-opaque","name":"cookie-user"}"#
            return try concurrencyIdentityResponse(body)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        let bearerTask = Task { try await service.identity(bearerToken: "hf_first_token", timeout: 1) }
        let cookieTask = Task { try await service.identity(cookieHeader: "session=first", timeout: 1) }
        await release.open()

        let bearerIdentity = try #require(try await bearerTask.value)
        let cookieIdentity = try #require(try await cookieTask.value)

        #expect(bearerIdentity.opaqueUserID == "bearer-opaque")
        #expect(cookieIdentity.opaqueUserID == "cookie-opaque")
        let requests = await transport.requests()
        #expect(requests.count(where: { $0.value(forHTTPHeaderField: "Authorization") != nil }) == 1)
        #expect(requests.count(where: { $0.value(forHTTPHeaderField: "Cookie") != nil }) == 1)
    }

    @Test
    func `failed in flight identity lookup is not retained as a long-lived cache hit`() async throws {
        let arrivals = AsyncArrivalCounter()
        let start = AsyncTestGate()
        let release = AsyncTestGate()
        let failingPhase = AsyncPhaseFlag()
        let transport = ProviderHTTPTransportStub { _ in
            let arrival = await arrivals.arrive()
            if arrival == 1 {
                await release.wait()
            }
            if await failingPhase.isActive() {
                throw ProviderPluginError.script("fixture identity outage")
            }
            return try concurrencyIdentityResponse(Self.userBody)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        var tasks: [Task<HuggingFaceIdentity?, any Error>] = [
            Task { try await service.identity(bearerToken: "hf_fixture_token", timeout: 1) },
        ]
        for _ in 1..<4 {
            tasks.append(Task {
                await start.wait()
                return try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
            })
        }
        await arrivals.waitForCount(1)
        await start.open()
        await release.open()

        var identities: [HuggingFaceIdentity?] = []
        for task in tasks {
            try await identities.append(task.value)
        }

        // The shared outage resolves every concurrent caller to "unavailable" without caching,
        // including late arrivals that missed the coalesced in-flight operation.
        #expect(identities.allSatisfy { $0 == nil })
        #expect(await service.cacheCount() == 0)

        // After the failing phase ends, a later lookup is a fresh miss that succeeds.
        await failingPhase.deactivate()
        let requestsBeforeRetry = await transport.requests().count
        let retried = try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
        #expect(retried?.opaqueUserID == "opaque-id-1")
        #expect(await transport.requests().count == requestsBeforeRetry + 1)
        #expect(await service.cacheCount() == 1)
    }

    @Test
    func `a cancelled identity waiter propagates cancellation without duplicating the whoami request`() async throws {
        let arrivals = AsyncArrivalCounter()
        let release = AsyncTestGate()
        let transport = ProviderHTTPTransportStub { _ in
            _ = await arrivals.arrive()
            await release.wait()
            return try concurrencyIdentityResponse(Self.userBody)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        let cancelledTask = Task { try await service.identity(bearerToken: "hf_fixture_token", timeout: 1) }
        let joinedTask = Task { try await service.identity(bearerToken: "hf_fixture_token", timeout: 1) }

        await arrivals.waitForCount(1)
        cancelledTask.cancel()
        await release.open()

        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTask.value
        }
        let identity = try #require(try await joinedTask.value)
        #expect(identity.opaqueUserID == "opaque-id-1")
        #expect(await transport.requests().count == 1)
        #expect(await service.cacheCount() == 1)
    }

    @Test
    func `a cancelled batch scope waiter propagates cancellation without duplicating the fetch`() async throws {
        let arrivals = AsyncArrivalCounter()
        let release = AsyncTestGate()
        let scope = HuggingFaceWalletBatchScope()
        let context = concurrencyFetchContext()
        let fetcher: HuggingFaceWalletBatchScope.ObservationFetcher = { _ in
            _ = await arrivals.arrive()
            await release.wait()
            return HuggingFaceBrowserWalletObservation(
                wallet: HuggingFaceWalletSnapshot(
                    balanceUSD: 4.5,
                    observedAt: Date(timeIntervalSince1970: 1_777_000_000)),
                identity: nil)
        }

        let cancelledTask = Task { try await scope.observation(for: context, fetcher: fetcher) }
        let joinedTask = Task { try await scope.observation(for: context, fetcher: fetcher) }

        await arrivals.waitForCount(1)
        cancelledTask.cancel()
        await release.open()

        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTask.value
        }
        let observation = try await joinedTask.value
        #expect(observation.wallet.balanceUSD == 4.5)
        #expect(await arrivals.count == 1)
    }

    @Test
    func `shared wallet work preserves the initiating caller's user initiated explicit retry scope`() async throws {
        let observer = ContextObserver()
        let scope = HuggingFaceWalletBatchScope()
        let context = concurrencyFetchContext()
        let fetcher: HuggingFaceWalletBatchScope.ObservationFetcher = { _ in
            await observer.record(
                ProviderInteractionContext.current,
                BrowserCookieAccessGate.hasExplicitRetryScopeForTesting)
            return HuggingFaceBrowserWalletObservation(
                wallet: HuggingFaceWalletSnapshot(
                    balanceUSD: 9.25,
                    observedAt: Date(timeIntervalSince1970: 1_777_000_000)),
                identity: nil)
        }

        // A user-initiated cookie refresh wraps the batch observation in the bounded explicit
        // browser-access retry scope. The shared operation must keep both task-local values.
        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await BrowserCookieAccessGate.withExplicitRetry {
                _ = try await scope.observation(for: context, fetcher: fetcher)
            }
        }

        #expect(await observer.interaction == .userInitiated)
        #expect(await observer.hasExplicitRetryScope == true)
    }

    @Test
    func `a detached operation without context preservation loses the browser access context`() async throws {
        // Test-local negative control (FP-194): shared work started on a detached task WITHOUT the
        // context-preserving wrapper observes the default background interaction and no explicit
        // retry scope, even though the initiating caller had both bound. Production code always
        // wraps the shared wallet work, but this control proves the positive test's assertions
        // actually detect a lost access context.
        let observer = ContextObserver()
        let probe: @Sendable () async throws -> Void = {
            await observer.record(
                ProviderInteractionContext.current,
                BrowserCookieAccessGate.hasExplicitRetryScopeForTesting)
        }
        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await BrowserCookieAccessGate.withExplicitRetry {
                let task = Task.detached(priority: .userInitiated) {
                    try await probe()
                }
                try await task.value
            }
        }

        #expect(await observer.interaction == .background)
        #expect(await observer.hasExplicitRetryScope == false)
    }
}

private actor ContextObserver {
    private(set) var interaction: ProviderInteraction?
    private(set) var hasExplicitRetryScope: Bool?

    func record(_ interaction: ProviderInteraction, _ hasExplicitRetryScope: Bool) {
        self.interaction = interaction
        self.hasExplicitRetryScope = hasExplicitRetryScope
    }
}
