import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthTests {
    @Test
    func `parses O auth credentials`() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "test-token",
            "refreshToken": "test-refresh",
            "expiresAt": 4102444800000,
            "scopes": ["usage:read"],
            "rateLimitTier": "default_claude_max_20x",
            "subscriptionType": "pro"
          }
        }
        """
        let creds = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "test-token")
        #expect(creds.refreshToken == "test-refresh")
        #expect(creds.scopes == ["usage:read"])
        #expect(creds.rateLimitTier == "default_claude_max_20x")
        #expect(creds.subscriptionType == "pro")
        #expect(creds.isExpired == false)
    }

    @Test
    func `missing access token throws`() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "",
            "refreshToken": "test-refresh",
            "expiresAt": 1735689600000
          }
        }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func `missing O auth block throws`() {
        let json = """
        { "other": { "accessToken": "nope" } }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func `mcp O auth only keychain payload throws`() {
        let json = """
        {
          "mcpOAuth": {
            "plugin:slack:slack": {
              "accessToken": ""
            }
          }
        }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func `detects mcp O auth only keychain payload shape`() {
        let json = """
        {
          "mcpOAuth": {
            "craft": { "accessToken": "" }
          }
        }
        """
        let data = Data(json.utf8)
        #expect(ClaudeOAuthCredentials.isMcpOAuthOnlyPayload(data: data))
    }

    @Test
    func `treats missing expiry as expired`() {
        let creds = ClaudeOAuthCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            rateLimitTier: nil)
        #expect(creds.isExpired == true)
    }

    @Test
    func `maps O auth usage to snapshot`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day": { "utilization": 30, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 5 }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_pro")
        #expect(snap.primary.usedPercent == 12.5)
        #expect(snap.primary.windowMinutes == 300)
        #expect(snap.secondary?.usedPercent == 30)
        #expect(snap.opus?.usedPercent == 5)
        #expect(snap.primary.resetsAt != nil)
        #expect(snap.loginMethod == "Claude Pro")
        #expect(snap.oauthHistoryOwnerIdentifier?.count == 64)
    }

    @Test
    func `maps O auth subscription type when rate limit tier is generic`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_ai",
            subscriptionType: "pro")
        #expect(snap.loginMethod == "Claude Pro")
    }

    @Test
    func `ignores merged O auth design usage window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_design": { "utilization": 44, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_routines": { "utilization": 18, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.count == 1)
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.title == "Daily Routines")
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 18)
    }

    @Test
    func `surfaces Fable scoped weekly limit from limits array`() throws {
        // Real shape observed 2026-07-03 during Anthropic's Fable 5 promotional access
        // window (up to 50% of the weekly limit on Fable 5): weekly caps have moved from
        // flat seven_day_* fields (now null) to a `limits` array with `scope.model.display_name`.
        let json = """
        {
          "five_hour": { "utilization": 11.0, "resets_at": "2026-07-03T00:30:00.282668+00:00" },
          "seven_day": { "utilization": 9.0, "resets_at": "2026-07-08T09:00:00.282694+00:00" },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "limits": [
            {
              "kind": "session", "group": "session", "percent": 11,
              "resets_at": "2026-07-03T00:30:00.282668+00:00", "scope": null, "is_active": true
            },
            {
              "kind": "weekly_all", "group": "weekly", "percent": 9,
              "resets_at": "2026-07-08T09:00:00.282694+00:00", "scope": null, "is_active": false
            },
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 5,
              "resets_at": "2026-07-08T09:00:00.283070+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false
            }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        let fable = snap.extraRateWindows.first(where: { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable?.title == "Fable only")
        #expect(fable?.window.usedPercent == 5)
        #expect(fable?.window.resetsAt != nil)
    }

    @Test
    func `ignores weekly scoped limit without a model display name`() throws {
        let json = """
        {
          "five_hour": { "utilization": 11.0, "resets_at": "2026-07-03T00:30:00.282668+00:00" },
          "limits": [
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 5,
              "resets_at": "2026-07-08T09:00:00.283070+00:00",
              "scope": { "model": null, "surface": null }, "is_active": false
            }
          ]
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.contains { $0.id.hasPrefix("claude-weekly-scoped-") } == false)
    }

    @Test
    func `ignores merged O auth omelette usage window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_omelette": { "utilization": 29, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_cowork": { "utilization": 9, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.count == 1)
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 9)
    }

    @Test
    func `maps O auth null cowork as zero routines window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_omelette": { "utilization": 29, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_cowork": null
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 0)
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
    }

    @Test
    func `prefers populated routines alias over null alias in mixed payload`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_design": null,
          "seven_day_omelette": { "utilization": 37, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_routines": null,
          "seven_day_cowork": { "utilization": 14, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 14)
    }

    @Test
    func `maps O auth extra usage`() throws {
        // OAuth API returns values in cents (minor units), same as Web API.
        // The normalization always converts to dollars (major units).
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2050,
            "used_credits": 325
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20.5)
        #expect(snap.providerCost?.used == 3.25)
        #expect(snap.providerCost?.period == "Monthly cap")
    }

    @Test
    func `maps O auth extra usage minor units as major units`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 520,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 5.2)
        #expect(snap.providerCost?.period == "Monthly cap")
    }

    @Test
    func `does not display spend limit 100x too high for enterprise O auth`() throws {
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 763,
            "utilization": 38.15,
            "currency": "EUR"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            subscriptionType: "enterprise")
        #expect(snap.loginMethod == "Claude Enterprise")
        #expect(snap.primary.usedPercent == 38.15)
        #expect(snap.primaryWindowKind == .spendLimit)
        #expect(snap.primary.windowMinutes == nil)
        #expect(snap.primary.resetDescription == "Spend limit: €7.63 / €20.00")
        #expect(snap.secondary == nil)
        #expect(snap.providerCost?.period == "Spend limit")
        #expect(snap.providerCost?.currencyCode == "EUR")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 7.63)

        let usage = ClaudeOAuthFetchStrategy._snapshotForTesting(from: snap)
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.period == "Spend limit")
        #expect(usage.providerCost?.limit == 20)
        #expect(usage.providerCost?.used == 7.63)
    }

    @Test
    func `maps O auth spend limit without plan metadata from minor units`() throws {
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 763,
            "utilization": 38.15,
            "currency": "EUR"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.loginMethod == nil)
        #expect(snap.primaryWindowKind == .spendLimit)
        #expect(snap.primary.usedPercent == 38.15)
        #expect(snap.primary.resetDescription == "Spend limit: €7.63 / €20.00")
        #expect(snap.providerCost?.period == "Spend limit")
        #expect(snap.providerCost?.currencyCode == "EUR")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 7.63)
    }

    @Test
    func `maps large enterprise O auth spend limit from minor units`() throws {
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 1000000,
            "used_credits": 123456,
            "utilization": 12.3456,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            subscriptionType: "enterprise")
        #expect(snap.primaryWindowKind == .spendLimit)
        #expect(snap.primary.usedPercent == 12.3456)
        #expect(snap.primary.resetDescription == "Spend limit: $1,234.56 / $10,000.00")
        #expect(snap.providerCost?.period == "Spend limit")
        #expect(snap.providerCost?.limit == 10000)
        #expect(snap.providerCost?.used == 1234.56)
    }

    @Test
    func `normalizes high limit O auth extra usage`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 200000,
            "used_credits": 22200,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_pro")
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 2000)
        #expect(snap.providerCost?.used == 222)
    }

    @Test
    func `normalizes O auth extra usage cents to major units`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 200000,
            "used_credits": 22200,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 2000)
        #expect(snap.providerCost?.used == 222)
    }

    @Test
    func `prefers opus when sonnet missing`() throws {
        let json = """
        {
          "five_hour": { "utilization": 10, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_opus": { "utilization": 42 }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.opus?.usedPercent == 42)
    }

    @Test
    func `includes body in O auth403 error`() {
        let err = ClaudeOAuthFetchError.serverError(
            403,
            "HTTP 403: OAuth token does not meet scope requirement user:profile")
        #expect(err.localizedDescription.contains("user:profile"))
        #expect(err.localizedDescription.contains("HTTP 403"))
    }

    @Test
    func `O auth429 error gives actionable guidance without raw body`() {
        let err = ClaudeOAuthFetchError.rateLimited(retryAfter: nil)
        #expect(err.localizedDescription.contains("rate limited"))
        #expect(err.localizedDescription.contains("claude logout && claude login"))
        #expect(!err.localizedDescription.contains("rate_limit_error"))
    }

    @Test
    func `O auth429 usage fetch surfaces guidance without raw JSON`() async throws {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            ClaudeOAuthCredentials(
                accessToken: "rate-limited-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }
        let fetchOverride: (@Sendable (String, Bool) async throws -> OAuthUsageResponse)? = { _, _ in
            throw ClaudeOAuthFetchError.rateLimited(retryAfter: nil)
        }

        do {
            _ = try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride) {
                try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                    loadCredsOverride,
                    operation: {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    })
            }
            Issue.record("Expected OAuth rate limit to fail with guidance")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return
            }
            #expect(message.contains("rate limited"))
            #expect(message.contains("claude logout && claude login"))
            #expect(!message.contains("rate_limit_error"))
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }
    }

    @Test
    func `O auth usage rate limit gate blocks background retries until cooldown`() {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let retryAfter = now.addingTimeInterval(120)
        let accountA = "test-auth-token"
        let accountB = "test-token-placeholder"

        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: accountA, now: now) == nil)
        ClaudeOAuthUsageRateLimitGate.recordRateLimit(
            accessToken: accountA,
            retryAfter: retryAfter,
            now: now)

        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: accountA, now: now) == retryAfter)
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: accountB, now: now) == nil)
        #expect(
            ClaudeOAuthUsageRateLimitGate.blockedUntil(
                accessToken: accountA,
                interaction: .background,
                now: now) == retryAfter)
        #expect(
            ClaudeOAuthUsageRateLimitGate.blockedUntil(
                accessToken: accountA,
                interaction: .userInitiated,
                now: now) == nil)
        #expect(
            ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(
                accessToken: accountA,
                now: now.addingTimeInterval(119)) != nil)
        #expect(
            ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(
                accessToken: accountA,
                now: now.addingTimeInterval(121)) == nil)
    }

    @Test
    func `O auth cooldown storage is private and cleans stale entries`() {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let accessToken = "test-auth-token"
        let preferenceName = ClaudeOAuthUsageRateLimitGate.storageKeyForTesting(accessToken: accessToken)
        let prefix = "claudeOAuthUsageRateLimitBlockedUntilV2."
        let legacyKey = "claudeOAuthUsageRateLimitBlockedUntilV1"
        let expiredKey = prefix + "expired"
        let malformedKey = prefix + "malformed"
        UserDefaults.standard.set(now.addingTimeInterval(600).timeIntervalSince1970, forKey: legacyKey)
        UserDefaults.standard.set(now.addingTimeInterval(-1).timeIntervalSince1970, forKey: expiredKey)
        UserDefaults.standard.set("not-a-date", forKey: malformedKey)

        ClaudeOAuthUsageRateLimitGate.recordRateLimit(
            accessToken: accessToken,
            retryAfter: now.addingTimeInterval(120),
            now: now)

        #expect(!preferenceName.contains(accessToken))
        #expect(String(preferenceName.dropFirst(prefix.count)).count == 64)
        #expect(UserDefaults.standard.object(forKey: preferenceName) != nil)
        #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)
        #expect(UserDefaults.standard.object(forKey: expiredKey) == nil)
        #expect(UserDefaults.standard.object(forKey: malformedKey) == nil)
    }

    @Test
    func `concurrent O auth cooldown writes keep every account and latest deadline`() async {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let shortDeadline = now.addingTimeInterval(60)
        let longDeadline = now.addingTimeInterval(600)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    ClaudeOAuthUsageRateLimitGate.recordRateLimit(
                        accessToken: index.isMultiple(of: 2) ? "test-auth-token" : "test-token-placeholder",
                        retryAfter: index.isMultiple(of: 3) ? longDeadline : shortDeadline,
                        now: now)
                }
            }
        }

        #expect(
            ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(
                accessToken: "test-auth-token",
                now: now) == longDeadline)
        #expect(
            ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(
                accessToken: "test-token-placeholder",
                now: now) == longDeadline)
    }

    @Test
    func `O auth transport cooldown is isolated and user recovery clears one account`() async throws {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let accountA = "test-auth-token"
        let accountB = "test-token-placeholder"
        let recorder = OAuthUsageTransportRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let bearerValue = authorization.replacingOccurrences(of: "Bearer ", with: "")
            let statusCode = await recorder.nextStatusCode(token: bearerValue)
            let body = statusCode == 200
                ? #"{"five_hour":{"utilization":12.5,"resets_at":"2026-07-09T18:00:00Z"}}"#
                : #"{"type":"rate_limit_error"}"#
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: statusCode == 429 ? ["Retry-After": "300"] : nil))
            return (Data(body.utf8), response)
        }

        do {
            _ = try await ProviderInteractionContext.$current.withValue(.background) {
                try await ClaudeOAuthUsageFetcher.fetchUsage(
                    accessToken: accountA,
                    detectClaudeVersion: false,
                    transport: transport)
            }
            Issue.record("Expected account A rate limit")
        } catch let error as ClaudeOAuthFetchError {
            guard case .rateLimited = error else {
                Issue.record("Expected account A rate limit, got \(error)")
                return
            }
        }

        do {
            _ = try await ProviderInteractionContext.$current.withValue(.background) {
                try await ClaudeOAuthUsageFetcher.fetchUsage(
                    accessToken: accountA,
                    detectClaudeVersion: false,
                    transport: transport)
            }
            Issue.record("Expected account A cooldown")
        } catch let error as ClaudeOAuthFetchError {
            guard case .rateLimited = error else {
                Issue.record("Expected account A cooldown, got \(error)")
                return
            }
        }
        #expect(await recorder.requestCount(token: accountA) == 1)

        _ = try await ProviderInteractionContext.$current.withValue(.background) {
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: accountB,
                detectClaudeVersion: false,
                transport: transport)
        }
        #expect(await recorder.requestCount(token: accountB) == 1)

        _ = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: accountA,
                detectClaudeVersion: false,
                transport: transport)
        }
        #expect(await recorder.requestCount(token: accountA) == 2)
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: accountA) == nil)

        _ = try await ProviderInteractionContext.$current.withValue(.background) {
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: accountA,
                detectClaudeVersion: false,
                transport: transport)
        }
        #expect(await recorder.requestCount(token: accountA) == 3)
    }

    @Test
    func `O auth retry after parses seconds`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "42"]))

        #expect(
            ClaudeOAuthUsageFetcher._retryAfterDateForTesting(from: response, now: now)
                == now.addingTimeInterval(42))
    }

    @Test
    func `O auth retry after parses HTTP date`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]))

        #expect(
            ClaudeOAuthUsageFetcher._retryAfterDateForTesting(from: response, now: now)
                == Date(timeIntervalSince1970: 1_445_412_480))
    }

    @Test
    func `oauth usage user agent uses claude code version`() {
        #expect(
            ClaudeOAuthUsageFetcher._userAgentForTesting(versionString: "2.1.70 (Claude Code)")
                == "claude-code/2.1.70")
        #expect(ClaudeOAuthUsageFetcher._userAgentForTesting(versionString: nil) == "claude-code/2.1.0")
    }

    @Test
    func `oauth usage fallback user agent skips version detector`() {
        var detectionCount = 0
        let fallback = ClaudeOAuthUsageFetcher._userAgentForTesting(
            detectClaudeVersion: false,
            versionDetector: {
                detectionCount += 1
                return "2.1.70 (Claude Code)"
            })

        #expect(fallback == "claude-code/2.1.0")
        #expect(detectionCount == 0)

        let detected = ClaudeOAuthUsageFetcher._userAgentForTesting(
            detectClaudeVersion: true,
            versionDetector: {
                detectionCount += 1
                return "2.1.70 (Claude Code)"
            })

        #expect(detected == "claude-code/2.1.70")
        #expect(detectionCount == 1)
    }

    @Test
    func `skips extra usage when disabled`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": false,
            "monthly_limit": 100,
            "used_credits": 10
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost == nil)
    }

    // MARK: - Scope-based strategy resolution

    @Test
    func `prefers O auth when available`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: true)
        #expect(strategy.dataSource == .oauth)
    }

    @Test
    func `falls back to CLI when O auth missing and CLI available`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .cli)
    }

    @Test
    func `falls back to web when O auth missing and CLI missing`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: false,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .web)
    }

    @Test
    func `falls back to CLI when O auth missing and web missing`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: false,
            hasCLI: true,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .cli)
    }
}

private actor OAuthUsageTransportRecorder {
    private var counts: [String: Int] = [:]

    func nextStatusCode(token: String) -> Int {
        let count = (self.counts[token] ?? 0) + 1
        self.counts[token] = count
        return token == "test-auth-token" && count == 1 ? 429 : 200
    }

    func requestCount(token: String) -> Int {
        self.counts[token] ?? 0
    }
}
