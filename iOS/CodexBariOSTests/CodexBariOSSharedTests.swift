import Foundation
import Testing
@testable import CodexBariOSShared

struct CodexBariOSSharedTests {
    @Test
    func `pkce code challenge matches RFC example`() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = OAuthSupport.codeChallenge(for: verifier)

        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test
    func `codex authorization request keeps expected oauth parameters`() throws {
        let redirectURI = try #require(URL(string: "http://localhost:1455/auth/callback"))
        let request = CodexOAuthClient.makeAuthorizationRequest(redirectURI: redirectURI)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "auth.openai.com")
        #expect(components.path == "/oauth/authorize")
        #expect(items["client_id"] == CodexOAuthClient.clientID)
        #expect(items["redirect_uri"] == redirectURI.absoluteString)
        #expect(items["scope"] == CodexOAuthClient.scope)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["id_token_add_organizations"] == "true")
        #expect(items["codex_cli_simplified_flow"] == "true")
        #expect(items["originator"] == CodexOAuthClient.originator)
        #expect(items["state"] == request.state)
        #expect(!(items["code_challenge"] ?? "").isEmpty)
    }

    @Test
    func `claude authorization request keeps expected oauth parameters`() throws {
        let redirectURI = ClaudeOAuthClient.redirectURI
        let request = ClaudeOAuthClient.makeAuthorizationRequest(redirectURI: redirectURI)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "claude.com")
        #expect(components.path == "/cai/oauth/authorize")
        #expect(items["code"] == "true")
        #expect(items["client_id"] == ClaudeOAuthClient.clientID)
        #expect(items["redirect_uri"] == redirectURI.absoluteString)
        #expect(items["scope"] == ClaudeOAuthClient.scope)
        #expect(items["scope"]?.contains("org:create_api_key") == true)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == request.state)
        #expect(!(items["code_challenge"] ?? "").isEmpty)
    }

    @Test
    func `claude web organization selection prefers chat-capable org`() throws {
        let json = """
        [
          {
            "uuid": "api-only",
            "capabilities": ["api"]
          },
          {
            "uuid": "chat-org",
            "capabilities": ["api", "chat"]
          }
        ]
        """

        let selected = try ClaudeWebUsageAPI._selectOrganizationIDForTesting(from: Data(json.utf8))

        #expect(selected == "chat-org")
    }

    @Test
    func `oauth-backed credentials expose refresh state`() {
        let staleCodex = CodexCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountID: nil,
            lastRefresh: Date(timeIntervalSinceNow: -(9 * 24 * 60 * 60)))
        let freshClaude = ClaudeCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: 300),
            scopes: ["user:profile"])
        let expiredClaude = ClaudeCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: -300),
            scopes: ["user:profile"])

        #expect(staleCodex.canRefresh)
        #expect(staleCodex.needsRefresh)
        #expect(freshClaude.canRefresh)
        #expect(freshClaude.isExpired == false)
        #expect(expiredClaude.isExpired)
    }

    @Test
    func `update timestamp uses concrete formatted time instead of relative copy`() {
        let now = Date(timeIntervalSince1970: 1_743_068_400)
        let sameDay = Date(timeIntervalSince1970: 1_743_065_700)
        let earlierDay = Date(timeIntervalSince1970: 1_742_980_000)

        #expect(
            DisplayFormat.updateTimestamp(sameDay, now: now)
                == sameDay.formatted(date: .omitted, time: .shortened))
        #expect(
            DisplayFormat.updateTimestamp(earlierDay, now: now)
                == earlierDay.formatted(date: .abbreviated, time: .shortened))
    }

    @Test
    func `codex entry mapping keeps credits and reset data`() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 32,
              "reset_at": 1767225600,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 14,
              "reset_at": 1767484800,
              "limit_window_seconds": 604800
            }
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": 61.5
          }
        }
        """
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let entry = CodexUsageAPI.makeEntry(response: response, updatedAt: Date(timeIntervalSince1970: 100))

        #expect(entry.provider == .codex)
        #expect(entry.creditsRemaining == 61.5)
        #expect(entry.primary?.usedPercent == 32)
        #expect(entry.secondary?.windowMinutes == 10_080)
    }

    @Test
    func `claude entry mapping keeps primary weekly and tertiary windows`() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 58.0,
            "resets_at": "2026-03-26T09:00:00Z"
          },
          "seven_day": {
            "utilization": 24.0,
            "resets_at": "2026-03-29T09:00:00Z"
          },
          "seven_day_sonnet": {
            "utilization": 12.0,
            "resets_at": "2026-03-29T09:00:00Z"
          }
        }
        """
        let response = try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: Data(json.utf8))
        let entry = try ClaudeUsageAPI.makeEntry(response: response, updatedAt: Date(timeIntervalSince1970: 100))

        #expect(entry.provider == .claude)
        #expect(entry.primary?.usedPercent == 58)
        #expect(entry.secondary?.usedPercent == 24)
        #expect(entry.tertiary?.usedPercent == 12)
    }

    @Test
    func `widget snapshot round trip keeps enabled providers`() throws {
        let snapshot = WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .codex,
                    updatedAt: Date(),
                    primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    tertiary: nil,
                    creditsRemaining: 12,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: []),
            ],
            enabledProviders: [.codex, .claude],
            generatedAt: Date())

        WidgetSnapshotStore.save(snapshot, bundleID: "com.steipete.CodexBariOSTests")
        let loaded = WidgetSnapshotStore.load(bundleID: "com.steipete.CodexBariOSTests")

        #expect(loaded?.enabledProviders == [.codex, .claude])
        #expect(loaded?.entries.first?.provider == .codex)
    }

    @Test
    func widgetRefreshDiagnosticsRoundTripKeepsStatusAndMessage() {
        let diagnostics = WidgetRefreshDiagnostics(
            requestCount: 7,
            triggeredAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_030),
            source: .switcherWidget,
            result: .cached,
            networkAttempted: true,
            message: "Widget kept cached data.",
            snapshotGeneratedAt: Date(timeIntervalSince1970: 1_700_000_010))

        WidgetRefreshDiagnosticsStore.save(diagnostics, bundleID: "com.steipete.CodexBariOSTests")
        let loaded = WidgetRefreshDiagnosticsStore.load(bundleID: "com.steipete.CodexBariOSTests")

        #expect(loaded == diagnostics)
    }

    @Test
    func `widget refresh diagnostics legacy payload falls back to defaults`() throws {
        let json = """
        {
          "triggeredAt": "2023-11-14T22:13:20Z",
          "completedAt": "2023-11-14T22:13:50Z",
          "result": "skipped",
          "message": "legacy",
          "snapshotGeneratedAt": "2023-11-14T22:13:30Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diagnostics = try decoder.decode(WidgetRefreshDiagnostics.self, from: Data(json.utf8))

        #expect(diagnostics.requestCount == 1)
        #expect(diagnostics.source == nil)
        #expect(diagnostics.networkAttempted == false)
        #expect(diagnostics.result == .skipped)
        #expect(diagnostics.message == "legacy")
    }

    @Test
    func `refresh cancellation detection unwraps nested network errors`() {
        #expect(UsageRefreshService.isCancellation(CancellationError()))
        #expect(UsageRefreshService.isCancellation(CodexUsageAPIError.networkError(URLError(.cancelled))))
        #expect(UsageRefreshService.isCancellation(ClaudeUsageAPIError.networkError(URLError(.cancelled))))
        #expect(UsageRefreshService.isCancellation(ClaudeWebUsageAPIError.networkError(URLError(.cancelled))))
        #expect(UsageRefreshService.isCancellation(CodexOAuthClientError.networkError(URLError(.cancelled))))
        #expect(UsageRefreshService.isCancellation(ClaudeOAuthClientError.networkError(URLError(.cancelled))))
        #expect(UsageRefreshService.isCancellation(CodexUsageAPIError.unauthorized) == false)
    }

    @Test
    func `merged snapshot keeps previous timestamp when refresh produced no new data`() {
        let previousGeneratedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let previousEntry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: previousGeneratedAt,
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: 50,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let previousSnapshot = WidgetSnapshot(
            entries: [previousEntry],
            enabledProviders: [.codex],
            generatedAt: previousGeneratedAt)

        let merged = UsageRefreshService.mergedSnapshot(
            previousSnapshot: previousSnapshot,
            enabledProviders: [.codex],
            entriesByProvider: [.codex: previousEntry],
            didUpdateAnyEntry: false)

        #expect(merged.entries == [previousEntry])
        #expect(merged.generatedAt == previousGeneratedAt)
    }

    @Test
    func `merged snapshot clears cached providers when refresh has no eligible credentials`() {
        let previousGeneratedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let previousEntry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: previousGeneratedAt,
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: 50,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let previousSnapshot = WidgetSnapshot(
            entries: [previousEntry],
            enabledProviders: [.codex],
            generatedAt: previousGeneratedAt)

        let merged = UsageRefreshService.mergedSnapshot(
            previousSnapshot: previousSnapshot,
            enabledProviders: [],
            entriesByProvider: [.codex: previousEntry],
            didUpdateAnyEntry: false)

        #expect(merged.entries.isEmpty)
        #expect(merged.enabledProviders.isEmpty)
        #expect(merged.generatedAt == previousGeneratedAt)
    }
}
