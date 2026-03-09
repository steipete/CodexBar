import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite
struct ClaudeUsageTests {
    private actor AsyncCounter {
        private var value = 0

        func increment() -> Int {
            self.value += 1
            return self.value
        }

        func current() -> Int {
            self.value
        }
    }

    private static func makeOAuthUsageResponse() throws -> OAuthUsageResponse {
        let json = """
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        return try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
    }

    @Test
    func parsesUsageJSONWithSonnetLimit() {
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 1, "resets": "11am (Europe/Vienna)" },
          "week_all_models": { "pct_used": 8, "resets": "Nov 21 at 5am (Europe/Vienna)" },
          "week_sonnet": { "pct_used": 0, "resets": "Nov 21 at 5am (Europe/Vienna)" }
        }
        """
        let data = Data(json.utf8)
        let snap = ClaudeUsageFetcher.parse(json: data)
        #expect(snap != nil)
        #expect(snap?.primary.usedPercent == 1)
        #expect(snap?.secondary?.usedPercent == 8)
        #expect(snap?.primary.resetDescription == "11am (Europe/Vienna)")
    }

    @Test
    func oauthDelegatedRetry_retriesOnce_thenSucceeds() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()
        let usageResponse = try Self.makeOAuthUsageResponse()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = { _ in usageResponse }
        let delegatedOverride: (@Sendable (
            Date,
            TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
            _ = await delegatedCounter.increment()
            return .attemptedSucceeded
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            let call = await loadCounter.increment()
            if call == 1 {
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }
            return ClaudeOAuthCredentials(
                accessToken: "fresh-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }

        let snapshot = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride, operation: {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                        delegatedOverride,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride
                                .withValue(loadCredsOverride, operation: {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                })
                        })
                })
            }
        }

        #expect(await loadCounter.current() == 2)
        #expect(await delegatedCounter.current() == 1)
        #expect(snapshot.primary.usedPercent == 7)
        #expect(snapshot.secondary?.usedPercent == 21)
    }

    @Test
    func oauthDelegatedRetry_secondAttemptStillExpired_failsCleanly() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        do {
            let delegatedOverride: (@Sendable (
                Date,
                TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
                _ = await delegatedCounter.increment()
                return .attemptedSucceeded
            }
            let loadCredsOverride: (@Sendable (
                [String: String],
                Bool,
                Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
                _ = await loadCounter.increment()
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }

            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                        delegatedOverride,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                loadCredsOverride,
                                operation: {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                })
                        })
                }
            }
            Issue.record("Expected delegated retry to fail when credentials remain expired")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return
            }
            #expect(message.contains("delegated Claude CLI refresh"))
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }

        #expect(await loadCounter.current() == 2)
        #expect(await delegatedCounter.current() == 1)
    }

    @Test
    func oauthDelegatedRetry_autoMode_cliUnavailable_failsFast() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()

        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let delegatedOverride: (@Sendable (Date, TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator
            .Outcome)? = { _, _ in
            _ = await delegatedCounter.increment()
            return .cliUnavailable
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            _ = await loadCounter.increment()
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        }

        do {
            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                        delegatedOverride,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                loadCredsOverride,
                                operation: {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                })
                        })
                }
            }
            Issue.record("Expected delegated retry to fail fast when CLI is unavailable")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return
            }
            #expect(message.contains("Claude CLI is not available"))
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }

        // Auto-mode: should not attempt a second credential load.
        #expect(await loadCounter.current() == 1)
        #expect(await delegatedCounter.current() == 1)
    }

    @Test
    func oauthDelegatedRetry_autoMode_attemptedFailed_thenNonInteractiveReloadSucceeds() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()
        let usageResponse = try Self.makeOAuthUsageResponse()

        final class FlagBox: @unchecked Sendable {
            var allowKeychainPromptFlags: [Bool] = []
        }
        let flags = FlagBox()

        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = { _ in usageResponse }
        let delegatedOverride: (@Sendable (Date, TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator
            .Outcome)? = { _, _ in
            _ = await delegatedCounter.increment()
            return .attemptedFailed("no-change")
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, allowKeychainPrompt, _ in
            flags.allowKeychainPromptFlags.append(allowKeychainPrompt)
            let call = await loadCounter.increment()
            if call == 1 {
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }
            return ClaudeOAuthCredentials(
                accessToken: "fresh-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }

        let snapshot = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride, operation: {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                        delegatedOverride,
                        operation: {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride
                                .withValue(loadCredsOverride, operation: {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                })
                        })
                })
            }
        }

        #expect(await loadCounter.current() == 2)
        #expect(await delegatedCounter.current() == 1)
        #expect(snapshot.primary.usedPercent == 7)

        // User-initiated repair: if the delegated refresh couldn't sync silently, we may allow an interactive prompt
        // on the retry to help recovery.
        #expect(flags.allowKeychainPromptFlags.count == 2)
        #expect(flags.allowKeychainPromptFlags[1] == true)
    }

    @Test
    func oauthDelegatedRetry_onlyOnUserAction_background_suppressesDelegation() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()

        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true)

        let delegatedOverride: (@Sendable (
            Date,
            TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
            _ = await delegatedCounter.increment()
            return .attemptedSucceeded
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            _ = await loadCounter.increment()
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        }

        do {
            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                try await ProviderInteractionContext.$current.withValue(.background) {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(delegatedOverride) {
                        try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredsOverride) {
                            try await fetcher.loadLatestUsage(model: "sonnet")
                        }
                    }
                }
            }
            Issue.record("Expected delegated refresh to be suppressed in background")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return
            }
            #expect(message.contains("background repair is suppressed"))
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }

        #expect(await loadCounter.current() == 1)
        #expect(await delegatedCounter.current() == 0)
    }

    @Test
    func oauthDelegatedRetry_never_background_suppressesDelegationEvenForCLI() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()

        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true,
            allowBackgroundDelegatedRefresh: true)

        let delegatedOverride: (@Sendable (
            Date,
            TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
            _ = await delegatedCounter.increment()
            return .attemptedSucceeded
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            _ = await loadCounter.increment()
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        }

        do {
            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                try await ProviderInteractionContext.$current.withValue(.background) {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(delegatedOverride) {
                        try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredsOverride) {
                            try await fetcher.loadLatestUsage(model: "sonnet")
                        }
                    }
                }
            }
            Issue.record("Expected delegated refresh to be suppressed for prompt policy 'never'")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return
            }
            #expect(message.contains("Delegated refresh is disabled by 'never' keychain policy"))
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }

        #expect(await loadCounter.current() == 1)
        #expect(await delegatedCounter.current() == 0)
    }

    @Test
    func oauthBootstrap_onlyOnUserAction_background_startup_allowsInteractiveReadWhenNoCache() async throws {
        final class FlagBox: @unchecked Sendable {
            var allowKeychainPromptFlags: [Bool] = []
        }

        let flags = FlagBox()
        let usageResponse = try Self.makeOAuthUsageResponse()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true,
            allowStartupBootstrapPrompt: true)

        let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = { _ in usageResponse }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, allowKeychainPrompt, _ in
            flags.allowKeychainPromptFlags.append(allowKeychainPrompt)
            return ClaudeOAuthCredentials(
                accessToken: "fresh-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }

        let snapshot = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            try await ProviderRefreshContext.$current.withValue(.startup) {
                try await ProviderInteractionContext.$current.withValue(.background) {
                    try await ClaudeUsageFetcher.$hasCachedCredentialsOverride.withValue(false) {
                        try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride) {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredsOverride) {
                                try await fetcher.loadLatestUsage(model: "sonnet")
                            }
                        }
                    }
                }
            }
        }

        #expect(flags.allowKeychainPromptFlags == [true])
        #expect(snapshot.primary.usedPercent == 7)
    }

    @Test
    func oauthDelegatedRetry_onlyOnUserAction_background_allowsDelegationForCLI() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()
        let usageResponse = try Self.makeOAuthUsageResponse()

        final class FlagBox: @unchecked Sendable {
            var allowKeychainPromptFlags: [Bool] = []
        }
        let flags = FlagBox()

        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: false,
            allowBackgroundDelegatedRefresh: true)

        let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = { _ in usageResponse }
        let delegatedOverride: (@Sendable (
            Date,
            TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
            _ = await delegatedCounter.increment()
            return .attemptedSucceeded
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, allowKeychainPrompt, _ in
            flags.allowKeychainPromptFlags.append(allowKeychainPrompt)
            let call = await loadCounter.increment()
            if call == 1 {
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }
            return ClaudeOAuthCredentials(
                accessToken: "fresh-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }

        let snapshot = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
            try await ProviderInteractionContext.$current.withValue(.background) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride) {
                    try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(delegatedOverride) {
                        try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredsOverride) {
                            try await fetcher.loadLatestUsage(model: "sonnet")
                        }
                    }
                }
            }
        }

        #expect(await loadCounter.current() == 2)
        #expect(await delegatedCounter.current() == 1)
        #expect(snapshot.primary.usedPercent == 7)
        #expect(flags.allowKeychainPromptFlags.allSatisfy { !$0 })
    }

    @Test
    func parsesUsageJSONWhenWeeklyMissing() {
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 4, "resets": "11am (Europe/Vienna)" }
        }
        """
        let data = Data(json.utf8)
        let snap = ClaudeUsageFetcher.parse(json: data)
        #expect(snap != nil)
        #expect(snap?.primary.usedPercent == 4)
        #expect(snap?.secondary == nil)
    }

    @Test
    func parsesLegacyOpusAndAccount() {
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 2, "resets": "10:59pm (Europe/Vienna)" },
          "week_all_models": { "pct_used": 13, "resets": "Nov 21 at 4:59am (Europe/Vienna)" },
          "week_opus": { "pct_used": 0, "resets": "" },
          "account_email": " steipete@gmail.com ",
          "account_org": ""
        }
        """
        let data = Data(json.utf8)
        let snap = ClaudeUsageFetcher.parse(json: data)
        #expect(snap?.opus?.usedPercent == 0)
        #expect(snap?.opus?.resetDescription?.isEmpty == true)
        #expect(snap?.accountEmail == "steipete@gmail.com")
        #expect(snap?.accountOrganization == nil)
    }

    @Test
    func parsesUsageJSONWhenOnlySonnetLimitIsPresent() {
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 3, "resets": "11am (Europe/Vienna)" },
          "week_all_models": { "pct_used": 9, "resets": "Nov 21 at 5am (Europe/Vienna)" },
          "week_sonnet_only": { "pct_used": 12, "resets": "Nov 22 at 5am (Europe/Vienna)" }
        }
        """
        let data = Data(json.utf8)
        let snap = ClaudeUsageFetcher.parse(json: data)
        #expect(snap?.secondary?.usedPercent == 9)
        #expect(snap?.opus?.usedPercent == 12)
        #expect(snap?.opus?.resetDescription == "Nov 22 at 5am (Europe/Vienna)")
    }

    @Test
    func trimsAccountFields() throws {
        let cases: [[String: String?]] = [
            ["email": " steipete@gmail.com ", "org": "  Org  "],
            ["email": "", "org": " Claude Max Account "],
            ["email": nil, "org": " "],
        ]

        for entry in cases {
            var payload = [
                "ok": true,
                "session_5h": ["pct_used": 0, "resets": ""],
                "week_all_models": ["pct_used": 0, "resets": ""],
            ] as [String: Any]
            if let email = entry["email"] { payload["account_email"] = email }
            if let org = entry["org"] { payload["account_org"] = org }
            let data = try JSONSerialization.data(withJSONObject: payload)
            let snap = ClaudeUsageFetcher.parse(json: data)
            let emailRaw: String? = entry["email"] ?? String?.none
            let expectedEmail = emailRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedEmail = (expectedEmail?.isEmpty ?? true) ? nil : expectedEmail
            #expect(snap?.accountEmail == normalizedEmail)
            let orgRaw: String? = entry["org"] ?? String?.none
            let expectedOrg = orgRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedOrg = (expectedOrg?.isEmpty ?? true) ? nil : expectedOrg
            #expect(snap?.accountOrganization == normalizedOrg)
        }
    }

    @Test
    func liveClaudeFetchPTY() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_CLAUDE_FETCH"] == "1" else {
            return
        }
        let fetcher = ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0), dataSource: .cli)
        do {
            let snap = try await fetcher.loadLatestUsage()
            let opusUsed = snap.opus?.usedPercent ?? -1
            let weeklyUsed = snap.secondary?.usedPercent ?? -1
            let email = snap.accountEmail ?? "nil"
            let org = snap.accountOrganization ?? "nil"
            print(
                """
                Live Claude usage (PTY):
                session used \(snap.primary.usedPercent)%
                week used \(weeklyUsed)% 
                opus \(opusUsed)% 
                email \(email) org \(org)
                """)
            #expect(snap.primary.usedPercent >= 0)
        } catch {
            // Dump raw CLI text captured via `script` to help debug.
            let raw = try Self.captureClaudeUsageRaw(timeout: 15)
            print("RAW CLAUDE OUTPUT BEGIN\n\(raw)\nRAW CLAUDE OUTPUT END")
            throw error
        }
    }

    private static func captureClaudeUsageRaw(timeout: TimeInterval) throws -> String {
        let process = Process()
        process.launchPath = "/usr/bin/script"
        process.arguments = [
            "-q",
            "/dev/null",
            "claude",
            "/usage",
            "--allowed-tools",
            "",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = nil

        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Web API tests

    @Test
    func liveClaudeFetchWebAPI() async throws {
        // Set LIVE_CLAUDE_WEB_FETCH=1 to run this test with real browser cookies
        guard ProcessInfo.processInfo.environment["LIVE_CLAUDE_WEB_FETCH"] == "1" else {
            return
        }
        let fetcher = ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0), dataSource: .web)
        let snap = try await fetcher.loadLatestUsage()
        let weeklyUsed = snap.secondary?.usedPercent ?? -1
        let opusUsed = snap.opus?.usedPercent ?? -1
        print(
            """
            Live Claude usage (Web API):
            session used \(snap.primary.usedPercent)%
            week used \(weeklyUsed)%
            opus \(opusUsed)%
            login method: \(snap.loginMethod ?? "nil")
            """)
        #expect(snap.primary.usedPercent >= 0)
    }

    @Test
    func claudeWebAPIHasSessionKeyCheck() {
        // Quick check that hasSessionKey returns a boolean (doesn't crash)
        let hasKey = ClaudeWebAPIFetcher.hasSessionKey(browserDetection: BrowserDetection(cacheTTL: 0))
        // We can't assert the value since it depends on the test environment
        #expect(hasKey == true || hasKey == false)
    }

    @Test
    func parsesClaudeWebAPIUsageResponse() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 4, "resets_at": "2025-12-29T23:00:00.000Z" },
          "seven_day_opus": { "utilization": 1 }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.sessionPercentUsed == 9)
        #expect(parsed.weeklyPercentUsed == 4)
        #expect(parsed.opusPercentUsed == 1)
        #expect(parsed.sessionResetsAt != nil)
        #expect(parsed.weeklyResetsAt != nil)
    }

    @Test
    func parsesClaudeWebAPIUsageResponseWhenWeeklyMissing() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.sessionPercentUsed == 9)
        #expect(parsed.weeklyPercentUsed == nil)
    }

    @Test
    func parsesClaudeWebAPIOverageSpendLimit() {
        let json = """
        {
          "monthly_credit_limit": 2000,
          "currency": "EUR",
          "used_credits": 0,
          "is_enabled": true
        }
        """
        let data = Data(json.utf8)
        let cost = ClaudeWebAPIFetcher._parseOverageSpendLimitForTesting(data)
        #expect(cost != nil)
        #expect(cost?.currencyCode == "EUR")
        #expect(cost?.limit == 20)
        #expect(cost?.used == 0)
        #expect(cost?.period == "Monthly")
    }

    @Test
    func parsesClaudeWebAPIOverageSpendLimitCents() {
        let json = """
        {
          "monthly_credit_limit": 12345,
          "currency": "USD",
          "used_credits": 6789,
          "is_enabled": true
        }
        """
        let data = Data(json.utf8)
        let cost = ClaudeWebAPIFetcher._parseOverageSpendLimitForTesting(data)
        #expect(cost?.currencyCode == "USD")
        #expect(cost?.limit == 123.45)
        #expect(cost?.used == 67.89)
    }

    @Test
    func parsesClaudeWebAPIOrganizationsResponse() throws {
        let json = """
        [
          { "uuid": "org-123", "name": "Example Org", "capabilities": [] }
        ]
        """
        let data = Data(json.utf8)
        let org = try ClaudeWebAPIFetcher._parseOrganizationsResponseForTesting(data)
        #expect(org.id == "org-123")
        #expect(org.name == "Example Org")
    }

    @Test
    func parsesClaudeWebAPIOrganizationsPrefersChatCapabilityOverApiOnly() throws {
        let json = """
        [
          { "uuid": "org-api", "name": "API Org", "capabilities": ["api"] },
          { "uuid": "org-chat", "name": "Chat Org", "capabilities": ["chat"] }
        ]
        """
        let data = Data(json.utf8)
        let org = try ClaudeWebAPIFetcher._parseOrganizationsResponseForTesting(data)
        #expect(org.id == "org-chat")
        #expect(org.name == "Chat Org")
    }

    @Test
    func parsesClaudeWebAPIOrganizationsPrefersHybridChatOrg() throws {
        let json = """
        [
          { "uuid": "org-api", "name": "API Org", "capabilities": ["api"] },
          { "uuid": "org-hybrid", "name": "Hybrid Org", "capabilities": ["api", "chat"] }
        ]
        """
        let data = Data(json.utf8)
        let org = try ClaudeWebAPIFetcher._parseOrganizationsResponseForTesting(data)
        #expect(org.id == "org-hybrid")
        #expect(org.name == "Hybrid Org")
    }

    @Test
    func parsesClaudeWebAPIAccountInfo() {
        let json = """
        {
          "email_address": "steipete@gmail.com",
          "memberships": [
            {
              "organization": {
                "uuid": "org-123",
                "name": "Example Org",
                "rate_limit_tier": "default_claude_max_20x",
                "billing_type": "stripe_subscription"
              }
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let info = ClaudeWebAPIFetcher._parseAccountInfoForTesting(data, orgId: "org-123")
        #expect(info?.email == "steipete@gmail.com")
        #expect(info?.loginMethod == "Claude Max")
    }

    @Test
    func parsesClaudeWebAPIAccountInfoSelectsMatchingOrg() {
        let json = """
        {
          "email_address": "steipete@gmail.com",
          "memberships": [
            {
              "organization": {
                "uuid": "org-other",
                "name": "Other Org",
                "rate_limit_tier": "claude_pro",
                "billing_type": "stripe_subscription"
              }
            },
            {
              "organization": {
                "uuid": "org-123",
                "name": "Example Org",
                "rate_limit_tier": "claude_team",
                "billing_type": "stripe_subscription"
              }
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let info = ClaudeWebAPIFetcher._parseAccountInfoForTesting(data, orgId: "org-123")
        #expect(info?.loginMethod == "Claude Team")
    }

    @Test
    func parsesClaudeWebAPIAccountInfoFallsBackToFirstMembership() {
        let json = """
        {
          "email_address": "steipete@gmail.com",
          "memberships": [
            {
              "organization": {
                "uuid": "org-first",
                "name": "First Org",
                "rate_limit_tier": "claude_enterprise",
                "billing_type": "invoice"
              }
            },
            {
              "organization": {
                "uuid": "org-second",
                "name": "Second Org",
                "rate_limit_tier": "claude_pro",
                "billing_type": "stripe_subscription"
              }
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let info = ClaudeWebAPIFetcher._parseAccountInfoForTesting(data, orgId: nil)
        #expect(info?.loginMethod == "Claude Enterprise")
    }

    @Test
    func claudeUsageFetcherInitWithDataSources() {
        // Verify we can create fetchers with both configurations
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let defaultFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)
        let webFetcher = ClaudeUsageFetcher(browserDetection: browserDetection, dataSource: .web)
        let cliFetcher = ClaudeUsageFetcher(browserDetection: browserDetection, dataSource: .cli)
        // Both should be valid instances (no crashes)
        let defaultVersion = defaultFetcher.detectVersion()
        let webVersion = webFetcher.detectVersion()
        let cliVersion = cliFetcher.detectVersion()
        #expect(defaultVersion?.isEmpty != true)
        #expect(webVersion?.isEmpty != true)
        #expect(cliVersion?.isEmpty != true)
    }
}

extension ClaudeUsageTests {
    @Test
    func oauthDelegatedRetry_experimental_background_ignoresOnlyOnUserActionSuppression() async throws {
        let loadCounter = AsyncCounter()
        let delegatedCounter = AsyncCounter()
        let usageResponse = try Self.makeOAuthUsageResponse()

        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true,
            allowBackgroundDelegatedRefresh: false)

        let fetchOverride: (@Sendable (String) async throws -> OAuthUsageResponse)? = { _ in usageResponse }
        let delegatedOverride: (@Sendable (
            Date,
            TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)? = { _, _ in
            _ = await delegatedCounter.increment()
            return .attemptedSucceeded
        }
        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, _ in
            let call = await loadCounter.increment()
            if call == 1 {
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }
            return ClaudeOAuthCredentials(
                accessToken: "fresh-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }

        let snapshot = try await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental,
            operation: {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    try await ProviderInteractionContext.$current.withValue(.background) {
                        try await ClaudeUsageFetcher.$hasCachedCredentialsOverride.withValue(true) {
                            try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(fetchOverride) {
                                try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride.withValue(
                                    delegatedOverride)
                                {
                                    try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(
                                        loadCredsOverride)
                                    {
                                        try await fetcher.loadLatestUsage(model: "sonnet")
                                    }
                                }
                            }
                        }
                    }
                }
            })

        #expect(await loadCounter.current() == 2)
        #expect(await delegatedCounter.current() == 1)
        #expect(snapshot.primary.usedPercent == 7)
    }

    @Test
    func oauthLoad_experimental_background_fallbackBlocked_propagatesOAuthFailure() async throws {
        final class FlagBox: @unchecked Sendable {
            var respectPromptCooldownFlags: [Bool] = []
        }
        let flags = FlagBox()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: true,
            allowBackgroundDelegatedRefresh: false)

        let loadCredsOverride: (@Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials)? = { _, _, respectKeychainPromptCooldown in
            flags.respectPromptCooldownFlags.append(respectKeychainPromptCooldown)
            throw ClaudeOAuthCredentialsError.notFound
        }

        await #expect(throws: ClaudeUsageError.self) {
            try await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                .securityCLIExperimental,
                operation: {
                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try await ProviderInteractionContext.$current.withValue(.background) {
                            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(loadCredsOverride) {
                                try await fetcher.loadLatestUsage(model: "sonnet")
                            }
                        }
                    }
                })
        }
        #expect(flags.respectPromptCooldownFlags == [true])
    }
}
