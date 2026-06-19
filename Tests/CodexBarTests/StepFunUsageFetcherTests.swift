import Foundation
import Testing
@testable import CodexBarCore

struct StepFunSettingsReaderTests {
    @Test
    func `reads STEPFUN_TOKEN`() {
        let env = ["STEPFUN_TOKEN": "some-oasis-token-value"]
        #expect(StepFunSettingsReader.token(environment: env) == "some-oasis-token-value")
    }

    @Test
    func `reads STEPFUN_USERNAME`() {
        let env = ["STEPFUN_USERNAME": "user@example.com"]
        #expect(StepFunSettingsReader.username(environment: env) == "user@example.com")
    }

    @Test
    func `reads STEPFUN_PASSWORD`() {
        let env = ["STEPFUN_PASSWORD": "secret123"]
        #expect(StepFunSettingsReader.password(environment: env) == "secret123")
    }

    @Test
    func `trims whitespace from token`() {
        let env = ["STEPFUN_TOKEN": "  some-token  "]
        #expect(StepFunSettingsReader.token(environment: env) == "some-token")
    }

    @Test
    func `strips double quotes from token`() {
        let env = ["STEPFUN_TOKEN": "\"some-token\""]
        #expect(StepFunSettingsReader.token(environment: env) == "some-token")
    }

    @Test
    func `strips single quotes from token`() {
        let env = ["STEPFUN_TOKEN": "'some-token'"]
        #expect(StepFunSettingsReader.token(environment: env) == "some-token")
    }

    @Test
    func `returns nil when no env vars present`() {
        #expect(StepFunSettingsReader.token(environment: [:]) == nil)
        #expect(StepFunSettingsReader.username(environment: [:]) == nil)
        #expect(StepFunSettingsReader.password(environment: [:]) == nil)
    }

    @Test
    func `returns nil for empty values`() {
        let env = ["STEPFUN_TOKEN": "", "STEPFUN_USERNAME": "", "STEPFUN_PASSWORD": ""]
        #expect(StepFunSettingsReader.token(environment: env) == nil)
        #expect(StepFunSettingsReader.username(environment: env) == nil)
        #expect(StepFunSettingsReader.password(environment: env) == nil)
    }

    @Test
    func `returns nil for whitespace-only values`() {
        let env = ["STEPFUN_TOKEN": "   "]
        #expect(StepFunSettingsReader.token(environment: env) == nil)
    }
}

struct StepFunProviderTokenResolverTests {
    @Test
    func `resolves token from environment`() {
        let env = ["STEPFUN_TOKEN": "my-test-token"]
        let resolution = ProviderTokenResolver.stepfunResolution(environment: env)
        #expect(resolution?.token == "my-test-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `returns nil when token absent`() {
        let resolution = ProviderTokenResolver.stepfunResolution(environment: [:])
        #expect(resolution == nil)
    }
}

struct StepFunUsageFetcherParsingTests {
    @Test
    func `parses real API response format with string timestamps and integer rates`() throws {
        // This matches the actual StepFun API response format:
        // - timestamps as strings (e.g. "1777528800")
        // - rates can be integers (e.g. 1) or floats (e.g. 0.99781543)
        let json = """
        {
            "status": 1,
            "desc": "",
            "five_hour_usage_left_rate": 1,
            "five_hour_usage_reset_time": "1777528800",
            "weekly_usage_left_rate": 0.99781543,
            "weekly_usage_reset_time": "1777899600"
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)

        #expect(snapshot.fiveHourUsageLeftRate == 1.0)
        #expect(snapshot.weeklyUsageLeftRate > 0.997 && snapshot.weeklyUsageLeftRate < 0.998)
    }

    @Test
    func `parses response with float rates and integer timestamps`() throws {
        let json = """
        {
            "status": 1,
            "five_hour_usage_left_rate": 0.75,
            "weekly_usage_left_rate": 0.5,
            "five_hour_usage_reset_time": 1746000000,
            "weekly_usage_reset_time": 1746500000
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)

        #expect(snapshot.fiveHourUsageLeftRate == 0.75)
        #expect(snapshot.weeklyUsageLeftRate == 0.5)
    }

    @Test
    func `throws on failed API status`() {
        let json = """
        {
            "status": 0,
            "message": "Unauthorized",
            "five_hour_usage_left_rate": 0.75,
            "weekly_usage_left_rate": 0.5,
            "five_hour_usage_reset_time": "1746000000",
            "weekly_usage_reset_time": "1746500000"
        }
        """
        let data = Data(json.utf8)
        #expect(throws: StepFunUsageError.self) {
            try StepFunUsageFetcher._parseSnapshotForTesting(data)
        }
    }

    @Test
    func `throws on missing fields`() {
        let json = """
        {
            "status": 1
        }
        """
        let data = Data(json.utf8)
        #expect(throws: StepFunUsageError.self) {
            try StepFunUsageFetcher._parseSnapshotForTesting(data)
        }
    }

    @Test
    func `throws on invalid JSON`() {
        let data = Data("not json".utf8)
        #expect(throws: StepFunUsageError.self) {
            try StepFunUsageFetcher._parseSnapshotForTesting(data)
        }
    }

    @Test
    func `snapshot maps to UsageSnapshot correctly`() throws {
        let json = """
        {
            "status": 1,
            "five_hour_usage_left_rate": 0.8,
            "weekly_usage_left_rate": 0.6,
            "five_hour_usage_reset_time": "1746000000",
            "weekly_usage_reset_time": "1746500000"
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)
        let usage = snapshot.toUsageSnapshot()

        // Five-hour window: 20% used (1.0 - 0.8)
        let primaryUsed = usage.primary?.usedPercent ?? 0
        #expect(primaryUsed > 19.9 && primaryUsed < 20.1)

        // Weekly window: 40% used (1.0 - 0.6)
        let secondaryUsed = usage.secondary?.usedPercent ?? 0
        #expect(secondaryUsed > 39.9 && secondaryUsed < 40.1)
        #expect(usage.secondary?.windowMinutes == 10080)

        // Identity
        #expect(usage.identity?.providerID == .stepfun)
        #expect(usage.identity?.loginMethod == "password")
    }

    @Test
    func `clamps used percent to 0-100 range`() throws {
        let json = """
        {
            "status": 1,
            "five_hour_usage_left_rate": 0.0,
            "weekly_usage_left_rate": 1,
            "five_hour_usage_reset_time": "1746000000",
            "weekly_usage_reset_time": "1746500000"
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)
        let usage = snapshot.toUsageSnapshot()

        // 0% remaining → 100% used
        #expect(usage.primary?.usedPercent == 100.0)
        // 100% remaining → 0% used (integer 1 parsed as 1.0)
        #expect(usage.secondary?.usedPercent == 0.0)
    }
}

struct StepFunTokenNormalizerTests {
    @Test
    func `extracts Oasis-Token from cookie header`() {
        let input = "Oasis-Token=abc123...def456; Oasis-Webid=someid"
        #expect(StepFunTokenNormalizer.normalize(input) == "abc123...def456")
    }

    @Test
    func `returns raw value when not a cookie header`() {
        let input = "abc123...def456"
        #expect(StepFunTokenNormalizer.normalize(input) == "abc123...def456")
    }

    @Test
    func `returns empty for empty string`() {
        #expect(StepFunTokenNormalizer.normalize("").isEmpty)
    }

    @Test
    func `trims whitespace`() {
        #expect(StepFunTokenNormalizer.normalize("  token123  ") == "token123")
    }
}

@Suite(.serialized)
struct StepFunTokenRefreshTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    @Test
    func `refresh token returns combined token pair`() async throws {
        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                #expect(request.url?.path.contains("RefreshToken") == true)
                #expect(request.value(forHTTPHeaderField: "Oasis-Token") == "old-access...old-refresh")
                #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("old-access...old-refresh") == true)
                recorder.recordRefreshCall()
                return Self.jsonResponse(
                    for: request,
                    body: """
                    {
                        "accessToken": {"raw": "new-access"},
                        "refreshToken": {"raw": "new-refresh"}
                    }
                    """)
            }

            let token = try await StepFunUsageFetcher.refreshToken(token: "old-access...old-refresh")
            #expect(token == "new-access...new-refresh")
            #expect(recorder.refreshCallCount == 1)
        }
    }

    @Test
    func `manual token auth failure refreshes token account and retries usage`() async throws {
        let accountID = UUID()
        let updateRecorder = StepFunTokenUpdateRecorder()

        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.contains("QueryStepPlanRateLimit") {
                    let call = recorder.recordUsageCall()
                    if call == 1 {
                        #expect(request.value(forHTTPHeaderField: "Cookie")?
                            .contains("old-access...old-refresh") == true)
                        return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
                    }

                    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("new-access...new-refresh") == true)
                    return Self.usageResponse(for: request)
                }

                if path.contains("RefreshToken") {
                    recorder.recordRefreshCall()
                    #expect(request.value(forHTTPHeaderField: "Oasis-Token") == "old-access...old-refresh")
                    return Self.jsonResponse(
                        for: request,
                        body: """
                        {
                            "accessToken": {"raw": "new-access"},
                            "refreshToken": {"raw": "new-refresh"}
                        }
                        """)
                }

                if path.contains("GetStepPlanStatus") {
                    return Self.jsonResponse(
                        for: request,
                        body: #"{"status":1,"subscription":{"name":"Plus","plan_type":1,"status":1}}"#)
                }

                return Self.jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }

            let settings = ProviderSettingsSnapshot.make(
                stepfun: ProviderSettingsSnapshot.StepFunProviderSettings(
                    cookieSource: .manual,
                    manualToken: "old-access...old-refresh"))
            let context = self.makeContext(
                settings: settings,
                selectedTokenAccountID: accountID,
                tokenUpdater: { provider, updatedAccountID, token in
                    #expect(provider == .stepfun)
                    #expect(updatedAccountID == accountID)
                    await updateRecorder.record(token)
                })

            let result = try await StepFunWebFetchStrategy().fetch(context)

            #expect(result.usage.identity?.loginMethod == "Plus")
            #expect(recorder.usageCallCount == 2)
            #expect(recorder.refreshCallCount == 1)
            let updatedToken = await updateRecorder.recordedToken()
            #expect(updatedToken == "new-access...new-refresh")
        }
    }

    @Test
    func `manual token auth failure refreshes settings token and retries usage`() async throws {
        let updateRecorder = StepFunTokenUpdateRecorder()

        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.contains("QueryStepPlanRateLimit") {
                    let call = recorder.recordUsageCall()
                    if call == 1 {
                        return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
                    }

                    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("new-access...new-refresh") == true)
                    return Self.usageResponse(for: request)
                }

                if path.contains("RefreshToken") {
                    recorder.recordRefreshCall()
                    return Self.jsonResponse(
                        for: request,
                        body: """
                        {
                            "accessToken": {"raw": "new-access"},
                            "refreshToken": {"raw": "new-refresh"}
                        }
                        """)
                }

                if path.contains("GetStepPlanStatus") {
                    return Self.jsonResponse(
                        for: request,
                        body: #"{"status":1,"subscription":{"name":"Plus","plan_type":1,"status":1}}"#)
                }

                return Self.jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }

            let settings = ProviderSettingsSnapshot.make(
                stepfun: ProviderSettingsSnapshot.StepFunProviderSettings(
                    cookieSource: .manual,
                    manualToken: "old-access...old-refresh"))
            let context = self.makeContext(
                settings: settings,
                manualTokenUpdater: { provider, token in
                    #expect(provider == .stepfun)
                    await updateRecorder.record(token)
                })

            _ = try await StepFunWebFetchStrategy().fetch(context)

            #expect(recorder.usageCallCount == 2)
            #expect(recorder.refreshCallCount == 1)
            let updatedToken = await updateRecorder.recordedToken()
            #expect(updatedToken == "new-access...new-refresh")
        }
    }

    @Test
    func `stale cached token falls back to configured env token`() async throws {
        CookieHeaderCache.store(provider: .stepfun, cookieHeader: "stale-access...stale-refresh", sourceLabel: "test")
        defer { CookieHeaderCache.clear(provider: .stepfun) }

        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.contains("QueryStepPlanRateLimit") {
                    let call = recorder.recordUsageCall()
                    if call == 1 {
                        #expect(request.value(forHTTPHeaderField: "Cookie")?
                            .contains("stale-access...stale-refresh") == true)
                        return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
                    }

                    #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("env-access...env-refresh") == true)
                    return Self.usageResponse(for: request)
                }

                if path.contains("RefreshToken") {
                    recorder.recordRefreshCall()
                    return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"expired"}"#)
                }

                if path.contains("GetStepPlanStatus") {
                    return Self.jsonResponse(
                        for: request,
                        body: #"{"status":1,"subscription":{"name":"Plus","plan_type":1,"status":1}}"#)
                }

                return Self.jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }

            let settings = ProviderSettingsSnapshot.make(
                stepfun: ProviderSettingsSnapshot.StepFunProviderSettings(cookieSource: .auto))
            let context = self.makeContext(
                settings: settings,
                env: ["STEPFUN_TOKEN": "env-access...env-refresh"])

            _ = try await StepFunWebFetchStrategy().fetch(context)

            #expect(recorder.usageCallCount == 2)
            #expect(recorder.refreshCallCount == 1)
            #expect(CookieHeaderCache.load(provider: .stepfun) == nil)
        }
    }

    @Test
    func `stale cached and env tokens fall back to env login credentials`() async throws {
        CookieHeaderCache.store(provider: .stepfun, cookieHeader: "stale-access...stale-refresh", sourceLabel: "test")
        defer { CookieHeaderCache.clear(provider: .stepfun) }

        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.isEmpty || path == "/" {
                    return Self.jsonResponse(
                        for: request,
                        body: "{}",
                        headers: ["Set-Cookie": "INGRESSCOOKIE=ingress-cookie; Path=/"])
                }

                if path.contains("RegisterDevice") {
                    return Self.jsonResponse(
                        for: request,
                        body: """
                        {
                            "accessToken": {"raw": "anon-access"},
                            "refreshToken": {"raw": "anon-refresh"}
                        }
                        """)
                }

                if path.contains("SignInByPassword") {
                    return Self.jsonResponse(
                        for: request,
                        body: """
                        {
                            "accessToken": {"raw": "login-access"},
                            "refreshToken": {"raw": "login-refresh"}
                        }
                        """)
                }

                if path.contains("QueryStepPlanRateLimit") {
                    let call = recorder.recordUsageCall()
                    if call == 1 {
                        #expect(request.value(forHTTPHeaderField: "Cookie")?
                            .contains("stale-access...stale-refresh") == true)
                        return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
                    }
                    if call == 2 {
                        #expect(request.value(forHTTPHeaderField: "Cookie")?
                            .contains("env-access...env-refresh") == true)
                        return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
                    }

                    #expect(request.value(forHTTPHeaderField: "Cookie")?
                        .contains("login-access...login-refresh") == true)
                    return Self.usageResponse(for: request)
                }

                if path.contains("RefreshToken") {
                    recorder.recordRefreshCall()
                    return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"expired"}"#)
                }

                if path.contains("GetStepPlanStatus") {
                    return Self.jsonResponse(
                        for: request,
                        body: #"{"status":1,"subscription":{"name":"Plus","plan_type":1,"status":1}}"#)
                }

                return Self.jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }

            let settings = ProviderSettingsSnapshot.make(
                stepfun: ProviderSettingsSnapshot.StepFunProviderSettings(cookieSource: .auto))
            let context = self.makeContext(
                settings: settings,
                env: [
                    "STEPFUN_TOKEN": "env-access...env-refresh",
                    "STEPFUN_USERNAME": "user@example.com",
                    "STEPFUN_PASSWORD": "password",
                ])

            _ = try await StepFunWebFetchStrategy().fetch(context)

            #expect(recorder.usageCallCount == 3)
            #expect(recorder.refreshCallCount == 1)
            #expect(CookieHeaderCache.load(provider: .stepfun)?.cookieHeader == "login-access...login-refresh")
        }
    }

    @Test
    func `post refresh non auth usage failure is not rewritten as auth guidance`() async throws {
        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.contains("QueryStepPlanRateLimit") {
                    let call = recorder.recordUsageCall()
                    if call == 1 {
                        return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
                    }
                    return Self.jsonResponse(for: request, statusCode: 500, body: #"{"error":"temporary"}"#)
                }

                if path.contains("RefreshToken") {
                    recorder.recordRefreshCall()
                    return Self.jsonResponse(
                        for: request,
                        body: """
                        {
                            "accessToken": {"raw": "new-access"},
                            "refreshToken": {"raw": "new-refresh"}
                        }
                        """)
                }

                return Self.jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }

            let settings = ProviderSettingsSnapshot.make(
                stepfun: ProviderSettingsSnapshot.StepFunProviderSettings(
                    cookieSource: .manual,
                    manualToken: "old-access...old-refresh"))
            let context = self.makeContext(settings: settings)

            do {
                _ = try await StepFunWebFetchStrategy().fetch(context)
                Issue.record("Expected post-refresh usage failure")
            } catch let StepFunUsageError.apiError(message) {
                #expect(message == "HTTP 500")
            } catch {
                Issue.record("Expected StepFunUsageError.apiError, got \(error)")
            }

            #expect(recorder.usageCallCount == 2)
            #expect(recorder.refreshCallCount == 1)
        }
    }

    @Test
    func `manual token refresh failure does not fall back to ambient env credentials`() async throws {
        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.contains("QueryStepPlanRateLimit") {
                    _ = recorder.recordUsageCall()
                    return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
                }

                if path.contains("RefreshToken") {
                    recorder.recordRefreshCall()
                    return Self.jsonResponse(for: request, statusCode: 401, body: #"{"error":"expired"}"#)
                }

                Issue.record("Manual token recovery should not call login endpoint: \(path)")
                return Self.jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }

            let settings = ProviderSettingsSnapshot.make(
                stepfun: ProviderSettingsSnapshot.StepFunProviderSettings(
                    cookieSource: .manual,
                    manualToken: "old-access...old-refresh"))
            let context = self.makeContext(
                settings: settings,
                env: [
                    "STEPFUN_USERNAME": "someone@example.com",
                    "STEPFUN_PASSWORD": "secret",
                ])

            do {
                _ = try await StepFunWebFetchStrategy().fetch(context)
                Issue.record("Expected manual token auth failure")
            } catch let StepFunUsageError.apiError(message) {
                #expect(message.contains("Refresh the Oasis-Token"))
            } catch {
                Issue.record("Expected StepFunUsageError.apiError, got \(error)")
            }

            #expect(recorder.usageCallCount == 1)
            #expect(recorder.refreshCallCount == 1)
        }
    }

    @Test
    func `non auth token wording does not trigger refresh recovery`() async throws {
        try await self.withStubProtocol { recorder in
            StepFunStubURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                if path.contains("QueryStepPlanRateLimit") {
                    _ = recorder.recordUsageCall()
                    return Self.jsonResponse(
                        for: request,
                        body: #"{"status":0,"message":"token plan status temporarily unavailable"}"#)
                }

                Issue.record("Non-auth usage error should not call recovery endpoint: \(path)")
                return Self.jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }

            let settings = ProviderSettingsSnapshot.make(
                stepfun: ProviderSettingsSnapshot.StepFunProviderSettings(
                    cookieSource: .manual,
                    manualToken: "old-access...old-refresh"))
            let context = self.makeContext(settings: settings)

            do {
                _ = try await StepFunWebFetchStrategy().fetch(context)
                Issue.record("Expected provider API error")
            } catch let StepFunUsageError.apiError(message) {
                #expect(message == "token plan status temporarily unavailable")
            } catch {
                Issue.record("Expected StepFunUsageError.apiError, got \(error)")
            }

            #expect(recorder.usageCallCount == 1)
            #expect(recorder.refreshCallCount == 0)
        }
    }

    private func makeContext(
        settings: ProviderSettingsSnapshot?,
        env: [String: String] = [:],
        selectedTokenAccountID: UUID? = nil,
        tokenUpdater: ProviderFetchContext.TokenAccountTokenUpdater? = nil,
        manualTokenUpdater: ProviderFetchContext.ProviderManualTokenUpdater? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: selectedTokenAccountID,
            tokenAccountTokenUpdater: tokenUpdater,
            providerManualTokenUpdater: manualTokenUpdater)
    }

    private func withStubProtocol(
        _ body: (StepFunRequestRecorder) async throws -> Void) async throws
    {
        let recorder = StepFunRequestRecorder()
        let registered = URLProtocol.registerClass(StepFunStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(StepFunStubURLProtocol.self)
            }
            StepFunStubURLProtocol.handler = nil
        }
        try await body(recorder)
    }

    private static func usageResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        self.jsonResponse(
            for: request,
            body: """
            {
                "status": 1,
                "five_hour_usage_left_rate": 0.8,
                "weekly_usage_left_rate": 0.6,
                "five_hour_usage_reset_time": "1777528800",
                "weekly_usage_reset_time": "1777899600"
            }
            """)
    }

    private static func jsonResponse(
        for request: URLRequest,
        statusCode: Int = 200,
        body: String,
        headers: [String: String] = ["Content-Type": "application/json"]) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers)!
        return (response, Data(body.utf8))
    }
}

private actor StepFunTokenUpdateRecorder {
    private var token: String?

    func record(_ token: String) {
        self.token = token
    }

    func recordedToken() -> String? {
        self.token
    }
}

private final class StepFunRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var usageCalls = 0
    private var refreshCalls = 0

    var usageCallCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.usageCalls
    }

    var refreshCallCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.refreshCalls
    }

    func recordUsageCall() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.usageCalls += 1
        return self.usageCalls
    }

    func recordRefreshCall() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.refreshCalls += 1
    }
}

private final class StepFunStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "platform.stepfun.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
