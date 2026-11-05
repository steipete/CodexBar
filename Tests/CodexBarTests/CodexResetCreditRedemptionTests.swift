import Foundation
import Testing
@testable import CodexBarCore

struct CodexResetCreditRedemptionTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-05T20:00:00+08:00")!
    static let requestID = UUID(uuidString: "512B2528-FC51-4BA3-A052-F470368178F0")!

    @Test
    func `fresh inventory resolves the hashed ID without persisting the provider ID`() async throws {
        let transport = Self.transport()
        let outcome = try await Self.consume(transport)
        #expect(outcome == .reset)
        let requests = await transport.requests()
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        let request = try #require(requests.last)
        #expect(request.url?.absoluteString ==
            "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "fixture-account")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == [
            "credit_id": "fixture-provider-id",
            "redeem_request_id": Self.requestID.uuidString.lowercased(),
        ])
        #expect(try !#require(String(data: data, encoding: .utf8)?.contains(Self.credit().id)))
    }

    @Test(arguments: [-1.0, 0, 1, 299, 300, 301])
    func `only spends an available credit within its last five minutes`(seconds: Double) async throws {
        let transport = Self.transport(seconds: seconds)
        let result = try await Self.consume(transport)
        let eligible = seconds > 0 && seconds <= 300
        #expect(result == (eligible ? .reset : .unavailable))
        #expect(await transport.requests().count == (eligible ? 2 : 1))
    }

    @Test(arguments: ["redeemed", "redeeming", "expired", "unknown"])
    func `does not spend used redeeming expired or unknown-status credits`(status: String) async throws {
        let transport = Self.transport(status: status)
        #expect(try await Self.consume(transport) == .unavailable)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func `never falls back to another credit when the requested card disappeared`() async throws {
        let transport = Self.transport(providerID: "another-card")
        #expect(try await Self.consume(transport) == .unavailable)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func `missing expiry and a different reset type cannot be auto redeemed`() async throws {
        for (expiry, resetType) in [(false, "codex_rate_limits"), (true, "other_limit")] {
            let transport = Self.transport(hasExpiry: expiry, resetType: resetType)
            #expect(try await Self.consume(transport) == .unavailable)
            #expect(await transport.requests().count == 1)
        }
    }

    @Test
    func `revoking the opt in or changing accounts during GET prevents POST`() async throws {
        let authorization = RedemptionAuthorization()
        let transport = Self.transport()
        await #expect(throws: CancellationError.self) {
            try await Self.consume(transport, authorized: { await authorization.next() })
        }
        #expect(await transport.requests().map(\.httpMethod) == ["GET"])
        let disabledTransport = Self.transport()
        await #expect(throws: CancellationError.self) {
            try await Self.consume(disabledTransport, authorized: { false })
        }
        #expect(await disabledTransport.requests().isEmpty)
    }

    @Test(arguments: ["reset", "already_redeemed", "nothing_to_reset", "no_credit"])
    func `handles each server outcome without inferring usage windows`(code: String) async throws {
        let result = try await Self.consume(Self.transport(code: code))
        #expect(result.rawValue == code)
    }

    @Test
    func `unknown success bodies and unauthorized responses remain failures`() async throws {
        for transport in [Self.transport(code: "unknown"), Self.transport(postStatus: 401)] {
            await #expect(throws: CodexOAuthFetchError.self) { try await Self.consume(transport) }
        }
    }

    static func consume(
        _ transport: ProviderHTTPTransportStub,
        authorized: @escaping @Sendable () async -> Bool = { true }) async throws -> CodexResetCreditRedemptionOutcome
    {
        try await CodexOAuthUsageFetcher.consumeExpiringRateLimitResetCredit(
            stableCreditID: self.credit().id,
            redeemRequestID: self.requestID,
            accessToken: "fixture-token",
            accountId: "fixture-account",
            env: ["CODEX_HOME": "/tmp/codexbar-auto-redemption-fixture"],
            now: { Self.now },
            isAuthorized: authorized,
            session: transport)
    }

    static func credit(seconds: Double = 300, providerID: String = "fixture-provider-id") -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: providerID,
            resetType: "codex_rate_limits",
            status: .available,
            grantedAt: self.now.addingTimeInterval(-86400),
            expiresAt: self.now.addingTimeInterval(seconds),
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }

    static func transport(
        seconds: Double = 300,
        status: String = "available",
        providerID: String = "fixture-provider-id",
        hasExpiry: Bool = true,
        resetType: String = "codex_rate_limits",
        code: String = "reset",
        postStatus: Int = 200) -> ProviderHTTPTransportStub
    {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if request.httpMethod == "POST" {
                return try (
                    Data("{\"code\":\"\(code)\",\"windows_reset\":1}".utf8),
                    #require(HTTPURLResponse(
                        url: url,
                        statusCode: postStatus,
                        httpVersion: nil,
                        headerFields: nil)))
            }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            let expiry: Any = hasExpiry ? formatter.string(from: Self.now.addingTimeInterval(seconds)) : NSNull()
            let payload: [String: Any] = ["available_count": 1, "credits": [[
                "id": providerID, "reset_type": resetType, "status": status,
                "granted_at": "2026-11-04T20:00:00+08:00", "expires_at": expiry,
            ]]]
            return try (
                JSONSerialization.data(withJSONObject: payload),
                #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }
}

private actor RedemptionAuthorization {
    private var calls = 0

    func next() -> Bool {
        self.calls += 1
        return self.calls == 1
    }
}
