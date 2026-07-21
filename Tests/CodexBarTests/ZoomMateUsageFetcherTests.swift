import Foundation
import Testing
@testable import CodexBarCore

struct ZoomMateUsageFetcherTests {
    private final class MessageRecorder: @unchecked Sendable {
        private var messages: [String] = []
        private let lock = NSLock()

        func append(_ message: String) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.messages.append(message)
        }

        func output() -> String {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.messages.joined(separator: "\n")
        }
    }

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

    private static let now = Date(timeIntervalSince1970: 1_782_800_000)

    /// Fully synthetic payload matching the first-party web client's decoded response shape.
    private static let sampleResponse = """
    { "data": { "credit_status": {
      "budget_cap": 12345.0, "used_credit": 678.0, "remaining_credit": 11667.0,
      "overage_credit": 0.0, "allow_overage": false,
      "cycle_start_date": 1893456000000, "cycle_end_date": 1896134399000,
      "is_quota_available": true, "is_unlimited": false } },
      "status_code": 200, "error_message": null }
    """

    @Test
    func `decodes credit status from sample JSON`() throws {
        let data = Data(Self.sampleResponse.utf8)
        struct Envelope: Decodable {
            struct DataBox: Decodable {
                let creditStatus: ZoomMateCreditStatus
                private enum CodingKeys: String, CodingKey { case creditStatus = "credit_status" }
            }

            let data: DataBox
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let status = envelope.data.creditStatus

        #expect(status.budgetCap == 12345)
        #expect(status.usedCredit == 678)
        #expect(status.remainingCredit == 11667)
        #expect(status.isUnlimited == false)
        #expect(status.cycleEndDate == 1_896_134_399_000)
    }

    @Test
    func `maps normal credit usage to primary window`() {
        let status = ZoomMateCreditStatus(
            budgetCap: 35000,
            usedCredit: 942,
            remainingCredit: 34058,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: 1_782_777_600_000,
            cycleEndDate: 1_785_455_999_000,
            isQuotaAvailable: true,
            isUnlimited: false)
        let snapshot = ZoomMateUsageSnapshot(creditStatus: status, updatedAt: Self.now).toUsageSnapshot()

        #expect(snapshot.primary != nil)
        #expect(abs((snapshot.primary?.usedPercent ?? 0) - 2.691_428_57) < 0.001)
        #expect(snapshot.primary?.resetsAt?.timeIntervalSince1970 == Double(1_785_455_999_000) / 1000)
        #expect(snapshot.primary?.resetDescription == "Credits")
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.providerID == .zoommate)
        #expect(snapshot.identity?.accountEmail == nil)
    }

    @Test
    func `unlimited plan reports zero percent and no reset`() {
        let status = ZoomMateCreditStatus(
            budgetCap: 35000,
            usedCredit: 942,
            remainingCredit: 34058,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: 1_782_777_600_000,
            cycleEndDate: 1_785_455_999_000,
            isQuotaAvailable: true,
            isUnlimited: true)
        let snapshot = ZoomMateUsageSnapshot(creditStatus: status, updatedAt: Self.now).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetsAt == nil)
    }

    @Test
    func `zero budget cap avoids divide by zero`() {
        let status = ZoomMateCreditStatus(
            budgetCap: 0,
            usedCredit: 0,
            remainingCredit: 0,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: nil,
            cycleEndDate: nil,
            isQuotaAvailable: false,
            isUnlimited: false)
        let snapshot = ZoomMateUsageSnapshot(creditStatus: status, updatedAt: Self.now).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetsAt == nil)
    }

    @Test
    func `fetch sends authorization and decodes credit status`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "ai.zoom.us")
            #expect(request.url?.path == "/ai-computer/api/v1/credits/status")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://zoommate.zoom.us")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://zoommate.zoom.us")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.sampleResponse.utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(
            authorization: "Bearer fake-token",
            headers: ["Origin": "https://attacker.example", "Referer": "https://attacker.example/path"])
        let snapshot = try await ZoomMateUsageFetcher.fetchCreditsStatus(
            context: context,
            now: Self.now,
            transport: stub)

        #expect(snapshot.creditStatus.usedCredit == 678)
    }

    @Test
    func `unauthorized response is invalid credentials`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{\"detail\": \"Missing Authorization header\"}".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(context: context, now: Self.now, transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `other server error is apiError`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data("boom".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(context: context, now: Self.now, transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.apiError = error else { return false }
            return true
        }
    }

    @Test
    func `malformed 200 body surfaces parseFailed`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"unexpected\": true}".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(context: context, now: Self.now, transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `manual curl capture extracts authorization and cookie`() throws {
        let curl = """
        curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' \\
          -H 'authorization: Bearer fake-manual-token' \\
          -H 'cookie: session=fake-cookie-value' \\
          -H 'origin: https://zoommate.zoom.us' \\
          -H 'referer: https://zoommate.zoom.us/'
        """

        let context = try #require(ZoomMateUsageFetcher.requestContext(from: curl))
        #expect(context.authorization == "Bearer fake-manual-token")
        #expect(context.headers["Cookie"] == "session=fake-cookie-value")
        #expect(context.headers["Origin"] == nil)
        #expect(context.headers["Referer"] == nil)
    }

    @Test
    func `manual curl capture rejects nonofficial and malformed targets`() {
        let captures = [
            "curl 'http://ai.zoom.us/ai-computer/api/v1/credits/status' -H 'authorization: Bearer fake'",
            "curl 'https://marketing.zoom.us/ai-computer/api/v1/credits/status' -H 'authorization: Bearer fake'",
            "curl 'https://zoom.us.attacker.com/ai-computer/api/v1/credits/status' -H 'authorization: Bearer fake'",
            "curl 'https://example.com/ai-computer/api/v1/credits/status' -H 'authorization: Bearer fake'",
            "curl 'https://ai.zoom.us/ai-computer/api/v1/credits/history' -H 'authorization: Bearer fake'",
            "curl 'https://ai.zoom.us:444/ai-computer/api/v1/credits/status' -H 'authorization: Bearer fake'",
            "curl --location 'https://ai.zoom.us/ai-computer/api/v1/credits/status' " +
                "-H 'authorization: Bearer fake'",
        ]

        for capture in captures {
            #expect(ZoomMateUsageFetcher.requestContext(from: capture) == nil)
        }
    }

    @Test
    func `manual curl capture accepts either interchangeable first-party host`() throws {
        let capture = "curl 'https://zoommate.zoom.us/ai-computer/api/v1/credits/status' " +
            "-H 'authorization: Bearer fake-manual-token'"

        let context = try #require(ZoomMateUsageFetcher.requestContext(from: capture))
        #expect(context.authorization == "Bearer fake-manual-token")
    }

    @Test
    func `credits status fails over to the alternate host on a non-auth failure`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            if request.url?.host == "ai.zoom.us" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(), response)
            }
            #expect(request.url?.host == "zoommate.zoom.us")
            #expect(request.url?.path == "/ai-computer/api/v1/credits/status")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.sampleResponse.utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        let snapshot = try await ZoomMateUsageFetcher.fetchCreditsStatus(
            context: context,
            now: Self.now,
            transport: stub)

        #expect(snapshot.creditStatus.usedCredit == 678)
        #expect(await stub.requests().count == 2)
    }

    @Test
    func `auth rejection does not fail over to the alternate host`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(context: context, now: Self.now, transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.invalidCredentials = error else { return false }
            return true
        }
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `parse failure does not fail over to the alternate host`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"unexpected\": true}".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateUsageFetcher.fetchCreditsStatus(context: context, now: Self.now, transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.parseFailed = error else { return false }
            return true
        }
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `mint fails over to the alternate host on a non-auth failure`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            if request.url?.host == "ai.zoom.us" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(), response)
            }
            #expect(request.url?.host == "zoommate.zoom.us")
            #expect(request.url?.path == "/ai-computer/api/v1/login")
            let body = "{\"success\": true, \"data\": {\"nak\": \"fake-minted-jwt\"}}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let minted = try await ZoomMateUsageFetcher.mintBearerToken(
            cookieHeader: "session=fake-cookie-value",
            transport: stub)

        #expect(minted.bearerToken == "fake-minted-jwt")
        #expect(await stub.requests().count == 2)
    }

    @Test
    func `host failover preserves cancellation without trying the alternate host`() async {
        var attemptedHosts: [String] = []

        do {
            let _: String = try await ZoomMateUsageFetcher.withAPIHostFailover { host in
                attemptedHosts.append(host)
                throw CancellationError()
            }
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(attemptedHosts == ["ai.zoom.us"])
    }

    @Test
    func `curl capture without authorization header yields nil context`() {
        let curl = """
        curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' \\
          -H 'cookie: session=fake-cookie-value'
        """

        #expect(ZoomMateUsageFetcher.requestContext(from: curl) == nil)
    }

    @Test
    func `manual strategy remains available so malformed captures surface an honest error`() async {
        let curl = "curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' " +
            "-H 'authorization: Bearer fake-manual-token'"
        let settings = ProviderSettingsSnapshot.make(
            zoommate: ProviderSettingsSnapshot.ZoomMateProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: curl))

        #expect(await ZoomMateWebFetchStrategy().isAvailable(Self.makeContext(settings: settings)))

        let emptySettings = ProviderSettingsSnapshot.make(
            zoommate: ProviderSettingsSnapshot.ZoomMateProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: nil))
        #expect(await ZoomMateWebFetchStrategy().isAvailable(Self.makeContext(settings: emptySettings)))
    }

    @Test
    func `manual mode with an empty or malformed capture returns noCapture`() async {
        let fetcher = ZoomMateUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))

        for capture in ["", "curl 'https://example.com' -H 'authorization: Bearer fake'"] {
            await #expect {
                _ = try await fetcher.resolveRequestContext(
                    manualCaptureOverride: capture,
                    timeout: 1,
                    logger: nil)
            } throws: { error in
                guard case ZoomMateUsageError.noCapture = error else { return false }
                return true
            }
        }
    }

    @Test
    func `auto strategy is available on macOS regardless of a stored manual capture`() async {
        let settings = ProviderSettingsSnapshot.make(
            zoommate: ProviderSettingsSnapshot.ZoomMateProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil))

        #if os(macOS)
        #expect(await ZoomMateWebFetchStrategy().isAvailable(Self.makeContext(settings: settings)))
        #else
        #expect(await ZoomMateWebFetchStrategy().isAvailable(Self.makeContext(settings: settings)) == false)
        #endif
    }

    @Test
    func `strategy is unavailable when cookie source is off`() async {
        let settings = ProviderSettingsSnapshot.make(
            zoommate: ProviderSettingsSnapshot.ZoomMateProviderSettings(
                cookieSource: .off,
                manualCookieHeader: nil))

        #expect(await ZoomMateWebFetchStrategy().isAvailable(Self.makeContext(settings: settings)) == false)
    }

    @Test
    func `mintBearerToken sends cookie and decodes nak from login bootstrap response`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.host == "ai.zoom.us")
            #expect(request.url?.path == "/ai-computer/api/v1/login")
            #expect(request.url?.query?.contains("continue=") == true)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fake-cookie-value")
            let body = """
            {"success": true, "data": {"nak": "fake-minted-jwt"}}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let minted = try await ZoomMateUsageFetcher.mintBearerToken(
            cookieHeader: "session=fake-cookie-value",
            transport: stub)

        #expect(minted.bearerToken == "fake-minted-jwt")
        #expect(minted.accountEmail == nil)
    }

    @Test
    func `mintBearerToken extracts email from user_profile when present`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let body = """
            {"success": true, "data": {"nak": "fake-minted-jwt", "user_profile": {
              "user_id": "fake-user-id", "email": "fake.user@example.com", "display_name": "Fake User"
            }}}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let minted = try await ZoomMateUsageFetcher.mintBearerToken(
            cookieHeader: "session=fake-cookie-value",
            transport: stub)

        #expect(minted.bearerToken == "fake-minted-jwt")
        #expect(minted.accountEmail == "fake.user@example.com")
    }

    @Test
    func `mintBearerToken tolerates missing user_profile without throwing`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let body = """
            {"success": true, "data": {"nak": "fake-minted-jwt"}}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let minted = try await ZoomMateUsageFetcher.mintBearerToken(
            cookieHeader: "session=fake-cookie-value",
            transport: stub)

        #expect(minted.bearerToken == "fake-minted-jwt")
        #expect(minted.accountEmail == nil)
    }

    @Test
    func `mintBearerToken tolerates user_profile with missing email without throwing`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let body = """
            {"success": true, "data": {"nak": "fake-minted-jwt", "user_profile": {
              "user_id": "fake-user-id", "display_name": "Fake User"
            }}}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let minted = try await ZoomMateUsageFetcher.mintBearerToken(
            cookieHeader: "session=fake-cookie-value",
            transport: stub)

        #expect(minted.bearerToken == "fake-minted-jwt")
        #expect(minted.accountEmail == nil)
    }

    @Test
    func `toUsageSnapshot populates identity accountEmail and loginMethod when email is known`() {
        let status = ZoomMateCreditStatus(
            budgetCap: 35000,
            usedCredit: 942,
            remainingCredit: 34058,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: 1_782_777_600_000,
            cycleEndDate: 1_785_455_999_000,
            isQuotaAvailable: true,
            isUnlimited: false)
        let snapshot = ZoomMateUsageSnapshot(creditStatus: status, updatedAt: Self.now)
            .toUsageSnapshot(accountEmail: "fake.user@example.com")

        #expect(snapshot.identity?.accountEmail == "fake.user@example.com")
        #expect(snapshot.identity?.loginMethod == "Cookie")
    }

    @Test
    func `mintBearerToken maps unauthorized to invalidCredentials`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }

        await #expect {
            _ = try await ZoomMateUsageFetcher.mintBearerToken(cookieHeader: "session=expired", transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `mintBearerToken surfaces parseFailed when nak is missing`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"success\": true, \"data\": {}}".utf8), response)
        }

        await #expect {
            _ = try await ZoomMateUsageFetcher.mintBearerToken(cookieHeader: "session=fake", transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `descriptor dashboard URL points to the credit usage pane`() {
        #expect(
            ZoomMateProviderDescriptor.descriptor.metadata.dashboardURL ==
                "https://zoommate.zoom.us/#/?settings=credit-usage")
    }

    #if os(macOS)
    @Test
    func `descriptor limits automatic cookie import to Chrome`() throws {
        let order = try #require(ZoomMateProviderDescriptor.descriptor.metadata.browserCookieOrder)
        #expect(order == [.chrome])
    }
    #endif

    @Test
    func `credential errors describe distinct recovery actions`() {
        #expect(ZoomMateUsageError.noCapture.localizedDescription.contains("ai.zoom.us"))
        #expect(ZoomMateUsageError.noSession.localizedDescription.contains("Chrome"))
        #expect(ZoomMateUsageError.invalidCredentials.localizedDescription.contains("rejected"))
    }

    @Test
    func `verbose logs omit captured cookies and bearer tokens`() async throws {
        let cookieMarker = "COOKIE_SECRET_MARKER"
        let tokenMarker = "TOKEN_SECRET_MARKER"
        let nakMarker = "NAK_SECRET_MARKER"
        let curl = """
        curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' \
          -H 'authorization: Bearer \(tokenMarker)' \
          -H 'cookie: session=\(cookieMarker)'
        """
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.sampleResponse.utf8), response)
        }
        let fetcher = ZoomMateUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))
        let messages = MessageRecorder()

        _ = try await fetcher.fetch(
            manualCaptureOverride: curl,
            logger: { messages.append($0) },
            transport: stub)

        let output = messages.output()
        #expect(!output.contains(cookieMarker))
        #expect(!output.contains(tokenMarker))
        #expect(output.contains("Forwarding captured headers: Cookie"))

        let mintStub = ProviderHTTPTransportStub { request in
            let body = "{\"success\": true, \"data\": {\"nak\": \"\(nakMarker)\"}}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        _ = try await ZoomMateUsageFetcher.cachedOrMintedToken(
            cookieHeader: "session=\(cookieMarker)",
            cache: ZoomMateBearerTokenCache(),
            timeout: 1,
            transport: mintStub,
            logger: { messages.append($0) })

        let mintOutput = messages.output()
        #expect(!mintOutput.contains(cookieMarker))
        #expect(!mintOutput.contains(nakMarker))
    }

    // MARK: - Bearer token expiry + in-memory cache

    /// Minimal unsigned JWT carrying only an `exp` claim, for cache-expiry tests.
    private static func makeJWT(exp: Int) -> String {
        func b64url(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url("{\"alg\":\"none\"}")).\(b64url("{\"exp\":\(exp)}")).sig"
    }

    @Test
    func `expiry decodes exp claim from a bearer JWT and ignores non-JWT tokens`() {
        let jwt = Self.makeJWT(exp: 1_782_800_000)
        #expect(ZoomMateUsageFetcher.expiry(fromJWT: jwt) == Date(timeIntervalSince1970: 1_782_800_000))
        // Tolerates an already-prefixed "Bearer " value.
        #expect(ZoomMateUsageFetcher.expiry(fromJWT: "Bearer \(jwt)") == Date(timeIntervalSince1970: 1_782_800_000))
        // Opaque (non-JWT) tokens are undatable → nil (caller must not cache them).
        #expect(ZoomMateUsageFetcher.expiry(fromJWT: "opaque-token") == nil)
    }

    @Test
    func `cachedOrMintedToken reuses an in-date token instead of re-minting`() async throws {
        let jwt = Self.makeJWT(exp: 9_999_999_999)
        let stub = ProviderHTTPTransportStub { request in
            let body = "{\"success\": true, \"data\": {\"nak\": \"\(jwt)\"}}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let cache = ZoomMateBearerTokenCache()

        let first = try await ZoomMateUsageFetcher.cachedOrMintedToken(
            cookieHeader: "session=abc",
            cache: cache,
            timeout: 1,
            transport: stub,
            logger: nil)
        let second = try await ZoomMateUsageFetcher.cachedOrMintedToken(
            cookieHeader: "session=abc",
            cache: cache,
            timeout: 1,
            transport: stub,
            logger: nil)

        #expect(first.bearerToken == jwt)
        #expect(second.bearerToken == jwt)
        #expect(await stub.requests().count == 1) // minted once, reused once
    }

    @Test
    func `cachedOrMintedToken re-mints a token without a decodable expiry`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let body = "{\"success\": true, \"data\": {\"nak\": \"opaque-not-a-jwt\"}}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let cache = ZoomMateBearerTokenCache()

        _ = try await ZoomMateUsageFetcher.cachedOrMintedToken(
            cookieHeader: "session=abc",
            cache: cache,
            timeout: 1,
            transport: stub,
            logger: nil)
        _ = try await ZoomMateUsageFetcher.cachedOrMintedToken(
            cookieHeader: "session=abc",
            cache: cache,
            timeout: 1,
            transport: stub,
            logger: nil)

        #expect(await stub.requests().count == 2) // undatable token is never cached
    }

    @Test
    func `cache serves an in-date entry but withholds one inside the refresh-skew window`() async {
        let cache = ZoomMateBearerTokenCache()
        let key = ZoomMateBearerTokenCache.key(forCookieHeader: "session=abc")
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // Expiry comfortably beyond the 60s skew → served.
        await cache.store(
            ZoomMateBearerTokenCache.Entry(
                token: "t",
                accountEmail: nil,
                expiry: now.addingTimeInterval(600)),
            forKey: key)
        #expect(await cache.validEntry(forKey: key, now: now) != nil)

        // Re-store with an expiry only 30s out (inside the 60s skew) → withheld and evicted.
        await cache.store(
            ZoomMateBearerTokenCache.Entry(
                token: "t",
                accountEmail: nil,
                expiry: now.addingTimeInterval(30)),
            forKey: key)
        #expect(await cache.validEntry(forKey: key, now: now) == nil)
        // Eviction is durable: a later lookup still misses.
        #expect(await cache.validEntry(forKey: key, now: now) == nil)
    }

    @Test
    func `invalidate evicts a cached token so the next call re-mints`() async throws {
        let jwt = Self.makeJWT(exp: 9_999_999_999)
        let stub = ProviderHTTPTransportStub { request in
            let body = "{\"success\": true, \"data\": {\"nak\": \"\(jwt)\"}}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let cache = ZoomMateBearerTokenCache()
        let key = ZoomMateBearerTokenCache.key(forCookieHeader: "session=abc")

        _ = try await ZoomMateUsageFetcher.cachedOrMintedToken(
            cookieHeader: "session=abc",
            cache: cache,
            timeout: 1,
            transport: stub,
            logger: nil)
        await cache.invalidate(forKey: key)
        _ = try await ZoomMateUsageFetcher.cachedOrMintedToken(
            cookieHeader: "session=abc",
            cache: cache,
            timeout: 1,
            transport: stub,
            logger: nil)

        #expect(await stub.requests().count == 2)
    }

    #if os(macOS)
    @Test
    func `cookie scope filter keeps session hosts and parent domain but drops unrelated subdomains`() {
        // Kept: exact session hosts + parent-scoped SSO cookies a browser sends to ai.zoom.us.
        #expect(ZoomMateCookieImporter.isSendable(cookieDomain: "ai.zoom.us"))
        #expect(ZoomMateCookieImporter.isSendable(cookieDomain: "zoommate.zoom.us"))
        #expect(ZoomMateCookieImporter.isSendable(cookieDomain: ".zoom.us"))
        #expect(ZoomMateCookieImporter.isSendable(cookieDomain: "zoom.us"))
        // Dropped: cookies host-scoped to unrelated *.zoom.us siblings, and non-Zoom lookalikes.
        #expect(!ZoomMateCookieImporter.isSendable(cookieDomain: "marketing.zoom.us"))
        #expect(!ZoomMateCookieImporter.isSendable(cookieDomain: "us05web.zoom.us"))
        #expect(!ZoomMateCookieImporter.isSendable(cookieDomain: "zoom.us.attacker.com"))
        #expect(!ZoomMateCookieImporter.isSendable(cookieDomain: ""))
    }
    #endif

    private static func makeContext(settings: ProviderSettingsSnapshot) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}
