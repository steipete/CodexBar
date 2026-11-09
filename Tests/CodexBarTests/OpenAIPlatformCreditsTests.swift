import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenAIPlatformSessionTests {
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

    private static let login = "/v1/dashboard/onboarding/login"
    private static let grants = "/v1/dashboard/billing/credit_grants"
    private static let grantsBody = #"{"total_available":12.5}"#

    /// A JWT with the `exp` claim of the access token the platform SPA stores, told apart by `sub`.
    private static func jwt(_ subject: String, expiresIn seconds: TimeInterval) -> String {
        let expiry = Date().addingTimeInterval(seconds).timeIntervalSince1970
        let payload = Data(#"{"exp":\#(expiry),"sub":"\#(subject)"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    /// A profile without the session, then one session per access token.
    private static func localStorage(_ accessTokens: [String]) -> BrowserLocalStorageAPI {
        let profiles = [BrowserLocalStorageAPI.Profile(
            id: "chrome:Default",
            label: "Chrome",
            entries: [.init(key: "oai/activeOrg", value: "org")])] + accessTokens.enumerated().map { index, token in
            BrowserLocalStorageAPI.Profile(
                id: "chrome:Profile \(index + 1)",
                label: "Profile \(index + 1)",
                entries: [.init(
                    key: "oai-auth:onboard",
                    value: #"{"accessToken":"\#(token)","refreshToken":"refresh-\#(index)","expiresIn":864000}"#)])
        }
        return BrowserLocalStorageAPI { origin, _, _, _ in origin == "https://platform.openai.com" ? profiles : [] }
    }

    enum Row: CaseIterable {
        case firstUnexpired
        case firstExpired
        case firstRejected
        case allExpired
    }

    @Test(arguments: Row.allCases)
    func `unexpired browser access tokens are tried in profile order without the Keychain`(row: Row) async throws {
        let first = Self.jwt("first", expiresIn: [.firstExpired, .allExpired].contains(row) ? -60 : 3600)
        let second = Self.jwt("second", expiresIn: row == .allExpired ? -60 : 3600)
        let logins: [String] = switch row {
        case .firstUnexpired: [first]
        case .firstExpired: [second]
        case .firstRejected: [first, second]
        case .allExpired: []
        }
        // Each rejected login moves on to the next profile, and the last one reaches credit grants.
        var responses: [(path: String, status: Int, body: String)] = logins.dropLast().map { _ in
            (Self.login, 401, "{}")
        }
        if !logins.isEmpty {
            responses += [
                (Self.login, 200, #"{"user":{"session":{"sensitive_id":"sess-fixture"}}}"#),
                (Self.grants, 200, Self.grantsBody),
            ]
        }
        let fixture = Fixture(responses)
        let recorder = KeychainCacheStore.OperationRecorder()
        let fetch = {
            try await KeychainCacheStore.withOperationRecorderForTesting(recorder) {
                try await OpenAIPlatformSession.creditGrants(
                    browserDetection: BrowserDetection(homeDirectory: "/nonexistent/openai-test", cacheTTL: 0),
                    localStorage: Self.localStorage([first, second]),
                    transport: fixture)
            }
        }

        if logins.isEmpty {
            let error = await #expect(throws: ProviderFetchClassifiedError.self) { try await fetch() }
            #expect(error?.kind == .authenticationExpired)
        } else {
            #expect(try await String(data: fetch(), encoding: .utf8) == Self.grantsBody)
        }
        #expect(recorder.operations.isEmpty)
        #expect(fixture.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
            == (logins + (logins.isEmpty ? [] : ["sess-fixture"])).map { "Bearer \($0)" })
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
