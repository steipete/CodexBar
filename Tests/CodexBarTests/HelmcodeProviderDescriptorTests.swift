import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct HelmcodeProviderDescriptorTests {
    @Test
    func `descriptor and app implementation are registered`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .helmcode)
        #expect(descriptor.metadata.displayName == "Helmcode")
        #expect(descriptor.metadata.browserCookieOrder == [.chrome])
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(descriptor.branding.color == ProviderColor(hex: 0x4934E1))
        #expect(try #require(ProviderImplementationRegistry.implementation(for: .helmcode))
            is HelmcodeProviderImplementation)

        let snapshot = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            creditsData: nil).toUsageSnapshot()
        #expect(descriptor.presentation.extraRateWindows(snapshot: snapshot).map(\.title) == [
            "deepseek-v4-flash",
            "glm5.2",
            "glm5.3",
            "mimo-v2.5",
            "qwen3.8-flash",
        ])
        #expect(descriptor.presentation.menu.usesPrimaryDescriptionAsDetail(snapshot: snapshot))
    }

    @Test @MainActor
    func `settings store persists deployment and feeds snapshots`() throws {
        let settings = testSettingsStore(suiteName: "HelmcodeProviderDescriptorTests-deployment")
        #expect(settings.helmcodeDeployment == .helmcode)
        #expect(settings.helmcodeSettingsSnapshot(tokenOverride: nil).deployment == .helmcode)

        settings.helmcodeDeployment = .nanBuilders
        #expect(settings.helmcodeDeployment == .nanBuilders)
        #expect(settings.providerConfig(for: .helmcode)?.region == "nanBuilders")

        let contribution = try ProviderDescriptorRegistry.descriptor(for: .helmcode)
            .settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(
                config: #require(settings.providerConfig(for: .helmcode)),
                account: nil))
        let cliSnapshot = contribution.map { ProviderSettingsSnapshot(contributions: [$0]) }
        #expect(cliSnapshot?.helmcode?.deployment == .nanBuilders)
    }

    @Test
    func `strategy is unavailable without an override cache or browser session`() async throws {
        try await Self.withEmptyCache {
            let stub = Self.unexpectedNetworkStub()
            let strategy = HelmcodeWebFetchStrategy()

            let cliContext = Self.makeContext(runtime: .cli)
            #expect(await strategy.isAvailable(cliContext) == false)

            await ProviderInteractionContext.$current.withValue(.background) {
                let appContext = Self.makeContext(runtime: .app)
                #expect(await strategy.isAvailable(appContext) == false)
            }
            _ = stub
        }
    }

    @Test
    func `off deployment yields no override even with environment cookie`() async throws {
        try await Self.withEmptyCache {
            let strategy = HelmcodeWebFetchStrategy()
            let offContext = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "session=env-value"],
                settings: HelmcodeProviderSettings(cookieSource: .off, manualCookieHeader: nil))
            #expect(await strategy.isAvailable(offContext) == false)
            #expect(HelmcodeCookieHeader.resolveCookieOverride(context: offContext) == nil)

            await #expect(throws: HelmcodeUsageError.missingCookies(.helmcode)) {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(
                    Self.unexpectedNetworkStub())
                {
                    try await strategy.fetch(offContext)
                }
            }
        }
    }

    @Test
    func `imported session fetch skips a rejected session and persists a valid one`() async throws {
        try await Self.withEmptyCache {
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                if request.value(forHTTPHeaderField: "Cookie") == "session=expired" {
                    return try Self.response(url: url, status: 401, body: Self.unauthenticatedBody())
                }
                return try Self.response(url: url, body: Self.quotaFixture())
            }
            let sessions = try [
                Self.makeSession(cookieHeader: "session=expired", value: "expired"),
                Self.makeSession(cookieHeader: "session=fresh", value: "fresh"),
            ]

            let snapshot = try await HelmcodeWebFetchStrategy.fetchImportedSessions(
                sessions,
                deployment: .helmcode)
            { session in
                try await HelmcodeWebFetchStrategy.fetchAndCacheSession(
                    session,
                    deployment: .helmcode,
                    transport: stub)
            }

            #expect(snapshot.toUsageSnapshot().primary?.resetDescription?.contains("glm5.3-flash") == true)
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode))?.cookieHeader == "session=fresh")
        }
    }

    @Test
    func `imported session fetch stops at an api error instead of trying the next session`() async throws {
        try await Self.withEmptyCache {
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                if request.value(forHTTPHeaderField: "Cookie") == "session=expired" {
                    return try Self.response(url: url, status: 401, body: Self.unauthenticatedBody())
                }
                return try Self.response(url: url, status: 500, body: Data(#"{"error":"boom"}"#.utf8))
            }
            let sessions = try [
                Self.makeSession(cookieHeader: "session=expired", value: "expired"),
                Self.makeSession(cookieHeader: "session=broken", value: "broken"),
            ]

            await #expect {
                _ = try await HelmcodeWebFetchStrategy.fetchImportedSessions(
                    sessions,
                    deployment: .helmcode)
                { session in
                    try await HelmcodeWebFetchStrategy.fetchAndCacheSession(
                        session,
                        deployment: .helmcode,
                        transport: stub)
                }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.apiError(500)
            }
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
        }
    }

    // MARK: - Helpers

    private static func withEmptyCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            for deployment in HelmcodeDeployment.allCases {
                CookieHeaderCache.clear(provider: .helmcode, scope: HelmcodeWebFetchStrategy.cacheScope(deployment))
            }
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        return try await operation()
    }

    private static func unexpectedNetworkStub() -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { _ in
            Issue.record("Unexpected network request")
            throw URLError(.badURL)
        }
    }

    private static func makeContext(
        runtime: CodexBarCore.ProviderRuntime,
        env: [String: String] = [:],
        settings: CodexBarCore.HelmcodeProviderSettings? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: .web,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 15,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings.map { snapshot in ProviderSettingsSnapshot.make(helmcode: snapshot) },
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func makeSession(
        cookieHeader: String,
        value: String) throws -> HelmcodeCookieImporter.SessionInfo
    {
        let record = BrowserCookieRecord(
            domain: "helmcode.com",
            name: "session",
            path: "/",
            value: value,
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: false,
            scope: .domain)
        let cookies = HelmcodeCookieImporter.makeCookies(from: [record])
        let url = try #require(URL(string: "https://cloud-api.helmcode.com/api/usage/quota"))
        #expect(HelmcodeCookieHeader.header(from: cookies, for: url) == cookieHeader)
        return HelmcodeCookieImporter.SessionInfo(cookies: cookies, sourceLabel: "Chrome Profile 1 (Test)")
    }

    private static func quotaFixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "quota",
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Helmcode"))
        return try Data(contentsOf: url)
    }

    private static func unauthenticatedBody() -> Data {
        Data(#"{"error":"unauthenticated"}"#.utf8)
    }

    private static func response(url: URL, status: Int = 200, body: Data) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil))
        return (body, response)
    }
}
