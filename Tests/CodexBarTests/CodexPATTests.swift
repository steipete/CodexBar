import Foundation
import Testing
@testable import CodexBarCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CodexPATTests {
    @Test
    func `parses personal access token credentials`() throws {
        let json = """
        {
          "OPENAI_API_KEY": null,
          "personal_access_token": "at-test-token"
        }
        """
        let credentials = try CodexOAuthCredentialsStore.parsePAT(data: Data(json.utf8))
        #expect(credentials.token == "at-test-token")
        #expect(credentials.source == .codexHome)
    }

    @Test
    func `OAuth parse ignores a PAT-only auth file`() {
        let json = """
        {
          "OPENAI_API_KEY": null,
          "personal_access_token": "at-test-token"
        }
        """
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        }
        guard case .missingTokens = error else {
            Issue.record("PAT-only auth.json must not be treated as OAuth credentials")
            return
        }
    }

    @Test
    func `PAT parse does not fall through to OAuth tokens`() throws {
        let json = """
        {
          "personal_access_token": "at-preferred",
          "OPENAI_API_KEY": "sk-test",
          "tokens": {
            "access_token": "oauth-access",
            "refresh_token": "oauth-refresh"
          }
        }
        """
        let pat = try CodexOAuthCredentialsStore.parsePAT(data: Data(json.utf8))
        let oauth = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(pat.token == "at-preferred")
        #expect(oauth.accessToken == "sk-test")
        #expect(oauth.isAPIKey)
    }

    @Test
    func `blank personal access token is missing`() {
        let json = """
        {
          "personal_access_token": "  "
        }
        """
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.parsePAT(data: Data(json.utf8))
        }
        guard case .missingTokens = error else {
            Issue.record("Whitespace PAT must not parse as a credential")
            return
        }
    }

    @Test
    func `auto usage strategy prefers PAT over OAuth`() {
        #expect(
            CodexProviderDescriptor.resolveUsageStrategy(
                selectedDataSource: .auto,
                hasOAuthCredentials: true,
                hasPATCredentials: true).dataSource == .pat)
        #expect(
            CodexProviderDescriptor.resolveUsageStrategy(
                selectedDataSource: .auto,
                hasOAuthCredentials: true,
                hasPATCredentials: false).dataSource == .oauth)
        #expect(
            CodexProviderDescriptor.resolveUsageStrategy(
                selectedDataSource: .pat,
                hasOAuthCredentials: true,
                hasPATCredentials: false).dataSource == .pat)
    }

    @Test
    func `User-Agent uses the Settings Codex version without a hardcoded fallback`() {
        #expect(
            CodexPATUsageFetcher._normalizedCLIVersionForTesting("codex-cli 0.148.0-alpha.9")
                == "0.148.0-alpha.9")
        #expect(CodexPATUsageFetcher._normalizedCLIVersionForTesting("1.2.3") == "1.2.3")
        #expect(CodexPATUsageFetcher._normalizedCLIVersionForTesting("  ") == nil)

        let userAgent = CodexPATUsageFetcher._userAgentForTesting(
            cliVersion: "codex-cli 0.148.0-alpha.9")
        #expect(userAgent.hasPrefix("codex_cli_rs/0.148.0-alpha.9 ("))
        #expect(userAgent.contains("; "))
        #expect(!userAgent.contains("codex-cli"))
    }

    @Test
    func `fetch context Settings version is the primary PAT User-Agent source`() {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            resolvedCLIVersion: "codex-cli 9.9.9-settings")
        #expect(
            CodexPATFetchStrategy._resolvedCLIVersionForTesting(context: context)
                == "codex-cli 9.9.9-settings")
    }

    @Test
    func `PAT whoami then usage send CLI User-Agent and skip OAuth extras`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let path = request.url?.path ?? ""
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at-test-token")
            #expect(request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
            #expect(
                request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("codex_cli_rs/1.2.3 (") == true)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)

            if path.hasSuffix("/user-auth-credential/whoami") {
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil))
                return (
                    Data(
                        """
                        {
                          "chatgpt_account_id": "acct-pat",
                          "chatgpt_plan_type": "team",
                          "email": "pat@example.com"
                        }
                        """.utf8), response)
            }

            #expect(path.hasSuffix("/wham/usage") || path.hasSuffix("/api/codex/usage"))
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-pat")
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
            return (
                Data(
                    """
                    {
                      "plan_type": "team",
                      "rate_limit": {
                        "primary_window": {
                          "used_percent": 68,
                          "reset_at": 1766948068,
                          "limit_window_seconds": 604800
                        },
                        "secondary_window": null
                      }
                    }
                    """.utf8), response)
        }

        let fetched = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await CodexPATUsageFetcher.fetchUsage(
                credentials: CodexPATCredentials(token: "at-test-token"),
                cliVersion: "1.2.3",
                env: ["CODEX_HOME": "/tmp/codexbar-pat-usage-test"])
        }

        #expect(fetched.whoami?.accountId == "acct-pat")
        #expect(fetched.whoami?.email == "pat@example.com")
        #expect(fetched.whoami?.planType == "team")
        #expect(fetched.usage.rateLimit?.primaryWindow?.usedPercent == 68)
        let requests = await transport.requests()
        #expect(
            requests.map { $0.url?.path } == [
                "/api/accounts/v1/user-auth-credential/whoami",
                "/backend-api/wham/usage",
            ])
    }

    @Test
    func `PAT usage mapping keeps pat source and does not request reset credits`() throws {
        let json = """
        {
          "plan_type": "team",
          "rate_limit": {
            "primary_window": {
              "used_percent": 68,
              "reset_at": 1766948068,
              "limit_window_seconds": 604800
            },
            "secondary_window": null
          }
        }
        """
        let result = try CodexPATFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            whoami: CodexPATWhoami(accountId: "acct-pat", email: "pat@example.com", planType: "team"))

        #expect(result.sourceLabel == "pat")
        #expect(result.strategyID == "codex.pat")
        #expect(result.strategyKind == .apiToken)
        #expect(result.codexResetCreditsAttempted)
        #expect(result.usage.codexResetCredits == nil)
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary?.usedPercent == 68)
        #expect(result.usage.accountEmail(for: .codex) == "pat@example.com")
        #expect(result.usage.loginMethod(for: .codex) == "team")
    }

    @Test
    func `explicit PAT source does not include OAuth or CLI strategies`() async {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let strategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(
            context)
        #expect(strategies.map(\.id) == ["codex.pat"])
        #expect(strategies.map(\.kind) == [.apiToken])
    }

    @Test
    func `PAT ignores managed and fail-closed CODEX_HOME when loading credentials`() {
        let failClosed = "/Users/test/Library/Application Support/CodexBar/managed-store-unreadable"
        let managedHome =
            "/Users/test/Library/Application Support/CodexBar/managed-codex-homes/00000000-0000-0000-0000-000000000001"
        let tempHome = "/tmp/codexbar-pat-usage-test"

        #expect(
            CodexPATFetchStrategy._credentialEnvironmentForTesting([
                "CODEX_HOME": failClosed, "PATH": "/usr/bin",
            ])[
                "CODEX_HOME",
            ] == nil)
        #expect(
            CodexPATFetchStrategy._credentialEnvironmentForTesting(["CODEX_HOME": managedHome])[
                "CODEX_HOME",
            ] == nil)
        #expect(
            CodexPATFetchStrategy._credentialEnvironmentForTesting(["CODEX_HOME": tempHome])["CODEX_HOME"]
                == tempHome)
        #expect(CodexPATFetchStrategy._credentialEnvironmentForTesting([:])["CODEX_HOME"] == nil)
    }

    @Test
    func `PAT strategy does not fall back to OAuth`() {
        let strategy = CodexPATFetchStrategy()
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        #expect(!strategy.shouldFallback(on: CodexOAuthFetchError.unauthorized, context: context))
        #expect(!strategy.shouldFallback(on: CodexOAuthFetchError.invalidResponse, context: context))
    }
}
