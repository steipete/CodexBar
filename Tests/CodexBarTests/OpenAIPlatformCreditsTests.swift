import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenAIPlatformSessionTests {
    private typealias Tokens = OpenAIPlatformSession.Tokens

    private final class Fixture: ProviderHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [(path: String, status: Int, body: String)]
        private(set) var requests: [URLRequest] = []

        init(_ responses: [(path: String, status: Int, body: String)]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let next = self.lock.withLock {
                self.requests.append(request)
                return self.responses.isEmpty ? nil : self.responses.removeFirst()
            }
            guard let next, next.path == request.url?.path, let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil, headerFields: nil)!
            return (Data(next.body.utf8), response)
        }
    }

    private static let token = "/oauth/token"
    private static let login = "/v1/dashboard/onboarding/login"
    private static let grants = "/v1/dashboard/billing/credit_grants"
    private static let grantsBody = #"{"total_available":12.5}"#
    private static let loginBody = #"{"user":{"session":{"sensitive_id":"sess-fixture"}}}"#
    private static let rotatedBody = #"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":864000}"#

    /// A JWT with the `exp` and `sub` claims of the access token the platform SPA stores.
    private static func jwt(expiresIn seconds: TimeInterval) -> String {
        let expiry = Date().addingTimeInterval(seconds).timeIntervalSince1970
        let payload = Data(#"{"exp":\#(expiry),"sub":"user-fixture"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    /// A profile without the session, a stale expired one, then the live one.
    private static func localStorage(accessToken: String) -> BrowserLocalStorageAPI {
        let onboard = { (access: String, refresh: String) in
            [BrowserLocalStorageAPI.Entry(
                key: "oai-auth:onboard",
                value: #"{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expiresIn":864000}"#)]
        }
        let profiles: [BrowserLocalStorageAPI.Profile] = [
            .init(id: "chrome:Default", label: "Chrome", entries: [.init(key: "oai/activeOrg", value: "org")]),
            .init(id: "chrome:Profile 1", label: "Old", entries: onboard(Self.jwt(expiresIn: -60), "refresh-old")),
            .init(id: "chrome:Profile 2", label: "Work", entries: onboard(accessToken, "refresh-browser")),
        ]
        return BrowserLocalStorageAPI { origin, _, _, _ in origin == "https://platform.openai.com" ? profiles : [] }
    }

    enum Route: CaseIterable {
        case browserAccess
        case storedAccess
        case storedRefresh
        case browserRefresh
        case otherAccount
    }

    @Test(arguments: Route.allCases)
    func `browser session token order reaches credit grants and persists rotations`(route: Route) async throws {
        let browserAccess = Self.jwt(expiresIn: [.browserAccess, .browserRefresh].contains(route) ? 3600 : -60)
        // The stored pair of an account no browser profile holds anymore is neither used nor refreshed.
        let stored = Tokens(
            accessToken: "access-stored",
            refreshToken: "refresh-stored",
            expiresAt: [.storedAccess, .otherAccount].contains(route) ? .distantFuture : .distantPast,
            subject: route == .otherAccount ? "user-other" : "user-fixture")
        let (bearer, refreshes): (String, [String]) = switch route {
        case .browserAccess: (browserAccess, [])
        case .storedAccess: ("access-stored", [])
        case .storedRefresh: ("access-new", ["refresh-stored"])
        case .browserRefresh: ("access-new", ["refresh-stored", "refresh-old", "refresh-browser"])
        case .otherAccount: ("access-new", ["refresh-old"])
        }
        var responses: [(path: String, status: Int, body: String)] = []
        if route == .browserRefresh {
            let rejected = #"{"error":"invalid_grant"}"#
            responses += [(Self.login, 401, "{}"), (Self.token, 400, rejected), (Self.token, 400, rejected)]
        }
        if !refreshes.isEmpty {
            responses.append((Self.token, 200, Self.rotatedBody))
        }
        responses += [(Self.login, 200, Self.loginBody), (Self.grants, 200, Self.grantsBody)]
        let fixture = Fixture(responses)

        try await KeychainCacheStore.withServiceOverrideForTesting("codexbar.tests.\(UUID().uuidString)") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            KeychainCacheStore.store(key: OpenAIPlatformSession.storeKey, entry: stored)

            let recorder = KeychainCacheStore.OperationRecorder()
            let body = try await KeychainCacheStore.withOperationRecorderForTesting(recorder) {
                try await OpenAIPlatformSession.creditGrants(
                    browserDetection: BrowserDetection(homeDirectory: "/nonexistent/openai-test", cacheTTL: 0),
                    localStorage: Self.localStorage(accessToken: browserAccess),
                    transport: fixture)
            }
            // A live browser token never touches the Keychain.
            #expect(recorder.operations.isEmpty == (route == .browserAccess))

            #expect(String(data: body, encoding: .utf8) == Self.grantsBody)
            let requests = fixture.requests
            let sentRefreshTokens = try requests.filter { $0.url?.path == Self.token }.map { request in
                let body = try #require(request.httpBody)
                let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
                #expect(json["grant_type"] == "refresh_token")
                return json["refresh_token"] ?? ""
            }
            #expect(sentRefreshTokens == refreshes)
            #expect(requests.last { $0.url?.path == Self.login }?.value(forHTTPHeaderField: "Authorization")
                == "Bearer \(bearer)")
            #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sess-fixture")
            guard case let .found(kept) = KeychainCacheStore.load(
                key: OpenAIPlatformSession.storeKey,
                as: Tokens.self)
            else {
                Issue.record("The stored pair must stay")
                return
            }
            if refreshes.isEmpty {
                #expect(kept == stored)
            } else {
                #expect(kept.accessToken == "access-new" && kept.refreshToken == "refresh-new")
                #expect(kept.subject == "user-fixture")
                #expect(kept.expiresAt > Date().addingTimeInterval(863_000))
            }
        }
    }

    @Test
    func `expired browser tokens are not refreshed without a durable store`() async {
        // A refresh would consume the browser's refresh token and keep the rotated pair nowhere.
        let fixture = Fixture([])
        let error = await #expect(throws: ProviderFetchClassifiedError.self) {
            try await OpenAIPlatformSession.creditGrants(
                browserDetection: BrowserDetection(homeDirectory: "/nonexistent/openai-test", cacheTTL: 0),
                localStorage: Self.localStorage(accessToken: Self.jwt(expiresIn: -60)),
                transport: fixture,
                storesTokens: false)
        }
        #expect(error?.kind == .authenticationExpired && fixture.requests.isEmpty)
    }
}

struct OpenAIPlatformCreditsSourceTests {
    private static func context(
        sourceMode: ProviderSourceMode,
        environment: [String: String] = [:]) -> ProviderFetchContext
    {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
    }

    private static func available(_ context: ProviderFetchContext) async -> [String] {
        var ids: [String] = []
        for strategy in await OpenAIAPIProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
            where await strategy.isAvailable(context)
        {
            ids.append(strategy.id)
        }
        return ids
    }

    @Test(arguments: [
        (ProviderSourceMode.api, ["OPENAI_ADMIN_KEY": "fixture"], ["openai.js"]),
        (.web, [:], ["openai.platform-web"]),
        (.auto, ["OPENAI_ADMIN_KEY": "fixture"], ["openai.js"]),
        (.auto, [:], []),
    ])
    func `auto keeps configured keys and only web reads the browser session`(
        mode: ProviderSourceMode,
        environment: [String: String],
        ids: [String]) async
    {
        #expect(await Self.available(Self.context(sourceMode: mode, environment: environment)) == ids)
    }

    @MainActor
    @Test
    func `implementation is available with a key or the browser session`() throws {
        let settings = testSettingsStore(
            suiteName: "OpenAIPlatformCreditsSourceTests-availability",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: []))
        let implementation = try #require(ProviderCatalog.implementation(for: .openai))
        let available = { (environment: [String: String]) in
            implementation.isAvailable(context: ProviderAvailabilityContext(
                provider: .openai,
                settings: settings,
                environment: environment))
        }
        #expect(!available([:]))
        #expect(available(["OPENAI_ADMIN_KEY": "fixture"]))
        settings.openAIUsageDataSource = .web
        #expect(available([:]))
    }
}
