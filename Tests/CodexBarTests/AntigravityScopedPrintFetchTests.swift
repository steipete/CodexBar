import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct AntigravityScopedPrintFetchTests {
    // MARK: - Token payload

    @Test
    func `file token payload encodes the agy storage format`() throws {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            idToken: "header.payload.signature",
            email: "user@example.com")
        let encoded = try JSONEncoder().encode(#require(AntigravityAgyFileTokenPayload(credentials: credentials)))
        let payload = try JSONDecoder().decode(AntigravityAgyFileTokenPayload.self, from: encoded)
        #expect(payload.token.accessToken == "access")
        #expect(payload.token.tokenType == "Bearer")
        #expect(payload.token.refreshToken == "refresh")
        #expect(payload.token.expiry == "2027-01-15T08:00:00Z")
        #expect(payload.authMethod == "consumer")
        #expect(payload.idToken == "header.payload.signature")
    }

    @Test
    func `file token payload refuses credentials without refresh token or expiry`() {
        let noRefresh = AntigravityOAuthCredentials(
            accessToken: "access", refreshToken: nil, expiryDate: Date(), email: "a@b.c")
        let noExpiry = AntigravityOAuthCredentials(
            accessToken: "access", refreshToken: "refresh", expiryDate: nil, email: "a@b.c")
        #expect(AntigravityAgyFileTokenPayload(credentials: noRefresh) == nil)
        #expect(AntigravityAgyFileTokenPayload(credentials: noExpiry) == nil)
    }

    // MARK: - Child environment

    @Test
    func `scoped child environment inherits only allowlisted keys`() {
        let parent = [
            "HOME": "/users/ambient",
            "PATH": "/ambient/bin",
            "TMPDIR": "/tmp/ambient",
            "LANG": "en_US.UTF-8",
            "HTTPS_PROXY": "http://proxy:8080",
            "GEMINI_API_KEY": "ambient-secret",
            "ANTHROPIC_API_KEY": "ambient-secret",
            AntigravityOAuthCredentialsStore.environmentCredentialsKey: "injected-creds",
            "AWS_PROFILE": "ambient-profile",
        ]
        let home = URL(fileURLWithPath: "/scoped/home", isDirectory: true)
        let child = AntigravityScopedAgyStaging.childEnvironment(from: parent, home: home)

        #expect(child["HOME"] == "/scoped/home")
        #expect(child["PWD"] == "/scoped/home")
        #expect(child["SSH_TTY"] == "codexbar-scoped")
        #expect(child["TMPDIR"] == "/tmp/ambient")
        #expect(child["LANG"] == "en_US.UTF-8")
        #expect(child["HTTPS_PROXY"] == "http://proxy:8080")
        #expect(child["PATH"]?.isEmpty == false)
        #expect(child["GEMINI_API_KEY"] == nil)
        #expect(child["ANTHROPIC_API_KEY"] == nil)
        #expect(child["AWS_PROFILE"] == nil)
        #expect(child[AntigravityOAuthCredentialsStore.environmentCredentialsKey] == nil)
    }

    // MARK: - Staging and identity verification

    @Test
    func `staging writes a private token file verified against the account claim`() throws {
        let credentials = self.credentials(email: "scoped@example.com")
        let staged = try AntigravityScopedAgyStaging.stage(
            credentials: credentials, expectedAccountEmail: "scoped@example.com")
        defer { try? FileManager.default.removeItem(at: staged.stagingRoot) }

        let tokenURL = staged.home
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let attrs = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let homeAttrs = try FileManager.default.attributesOfItem(atPath: staged.home.path)
        #expect((homeAttrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test
    func `staging rejects a token whose identity does not match the account`() throws {
        let credentials = self.credentials(email: "other@example.com")
        do {
            _ = try AntigravityScopedAgyStaging.stage(
                credentials: credentials, expectedAccountEmail: "scoped@example.com")
            Issue.record("A token for a different account must not be staged")
        } catch AntigravityScopedStagingError.identityUnverifiable {}
    }

    @Test
    func `staging accepts token-only credentials without an id_token claim`() throws {
        // Saved accounts created without the `openid` scope carry email,
        // tokens, and expiry but no ID token; they must still stage because
        // the post-run userinfo check binds the effective account.
        let credentials = AntigravityOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiryDate: Date().addingTimeInterval(3600),
            email: "scoped@example.com")
        let staged = try AntigravityScopedAgyStaging.stage(
            credentials: credentials, expectedAccountEmail: "scoped@example.com")
        defer { try? FileManager.default.removeItem(at: staged.stagingRoot) }

        let tokenURL = staged.home
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let payload = try JSONDecoder().decode(AntigravityAgyFileTokenPayload.self, from: Data(contentsOf: tokenURL))
        #expect(payload.token.accessToken == "access")
        #expect(payload.idToken == nil)
    }

    // MARK: - Refreshed credential persistence

    @Test
    func `refreshed credentials follow the staged payload after agy rewrites it`() throws {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh",
            expiryDate: Date(timeIntervalSince1970: 1_000_000),
            email: "scoped@example.com")
        let staged = try AntigravityScopedAgyStaging.stage(
            credentials: credentials, expectedAccountEmail: "scoped@example.com")
        defer { try? FileManager.default.removeItem(at: staged.stagingRoot) }

        // An unchanged staged file has nothing to persist.
        let originalPayload = try #require(AntigravityScopedAgyStaging.stagedTokenPayload(home: staged.home))
        #expect(AntigravityScopedAgyStaging.refreshedCredentials(
            payload: originalPayload, original: credentials) == nil)

        let tokenURL = staged.home
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let rewritten = AntigravityAgyFileTokenPayload(
            token: .init(
                accessToken: "fresh-access",
                tokenType: "Bearer",
                refreshToken: "fresh-refresh",
                expiry: "2030-01-01T00:00:00Z"),
            authMethod: "consumer",
            idToken: nil)
        try JSONEncoder().encode(rewritten).write(to: tokenURL)

        let refreshed = try #require(AntigravityScopedAgyStaging.refreshedCredentials(
            payload: rewritten, original: credentials))
        #expect(refreshed.accessToken == "fresh-access")
        #expect(refreshed.refreshToken == "fresh-refresh")
        #expect(refreshed.expiryDate == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(refreshed.email == "scoped@example.com")
    }

    // MARK: - Fallback wiring (platform-independent)

    @Test
    func `selected auto account uses the scoped report when legacy fails`() async throws {
        let strategy = AntigravityCLIHTTPSFetchStrategy()
        let expected = strategy.makeResult(
            usage: self.makeUsage(email: "scoped@example.com"), sourceLabel: "cli")
        let result = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
            context: self.makeContext(selected: true, env: self.accountEnv(email: "scoped@example.com")),
            legacyFetch: { throw AntigravityStatusProbeError.timedOut },
            reportFetch: {
                Issue.record("Ambient identity-free print stays suppressed for selected accounts")
                throw AntigravityStatusProbeError.notRunning
            },
            scopedReportFetch: { expected })
        #expect(result.usage.identity?.accountEmail == "scoped@example.com")
    }

    @Test
    func `scoped failure preserves the original error and never runs ambient print`() async {
        await #expect(throws: AntigravityStatusProbeError.timedOut) {
            try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
                context: self.makeContext(selected: true, env: self.accountEnv(email: "scoped@example.com")),
                legacyFetch: { throw AntigravityStatusProbeError.timedOut },
                reportFetch: {
                    Issue.record("Ambient identity-free print stays suppressed for selected accounts")
                    throw AntigravityStatusProbeError.notRunning
                },
                scopedReportFetch: {
                    throw AntigravityStatusProbeError.cliReportFailed(.executableNotFound)
                })
        }
    }

    @Test
    func `cancellation stops the pipeline before the scoped fetch`() async {
        await #expect(throws: CancellationError.self) {
            try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
                context: self.makeContext(selected: true, env: self.accountEnv(email: "scoped@example.com")),
                legacyFetch: { throw CancellationError() },
                reportFetch: {
                    Issue.record("Cancellation must stop the provider pipeline")
                    throw AntigravityStatusProbeError.notRunning
                },
                scopedReportFetch: {
                    Issue.record("Cancellation must not start a scoped subprocess")
                    throw AntigravityStatusProbeError.notRunning
                })
        }
    }

    @Test
    func `unselected auto fetch still uses the ambient print report`() async throws {
        let strategy = AntigravityCLIHTTPSFetchStrategy()
        let expected = strategy.makeResult(usage: self.makeUsage(email: nil), sourceLabel: "cli")
        let result = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
            context: self.makeContext(),
            legacyFetch: { throw AntigravityStatusProbeError.timedOut },
            reportFetch: { expected },
            scopedReportFetch: {
                Issue.record("Scoped fetch is reserved for selected or injected accounts")
                throw AntigravityStatusProbeError.notRunning
            })
        #expect(result.usage.identity?.accountEmail == nil)
    }

    @Test
    func `explicit cli mode never reaches the scoped fetch`() async throws {
        let strategy = AntigravityCLIHTTPSFetchStrategy()
        let expected = strategy.makeResult(usage: self.makeUsage(email: nil), sourceLabel: "cli")
        let result = try await AntigravityCLIHTTPSFetchStrategy.fetchWithReportFallback(
            context: self.makeContext(
                sourceMode: .cli, selected: true, env: self.accountEnv(email: "scoped@example.com")),
            legacyFetch: { throw AntigravityStatusProbeError.timedOut },
            reportFetch: { expected },
            scopedReportFetch: {
                Issue.record("Explicit cli mode stays bound to the ambient login")
                throw AntigravityStatusProbeError.notRunning
            })
        #expect(result.usage.identity?.accountEmail == nil)
    }

    // MARK: - Scoped subprocess (macOS only)

    #if os(macOS)
    @Test
    func `scoped Starter reports preserve both weekly groups`() async throws {
        let groups: [[String: Any]] = [("Gemini Models", "gemini"), ("Claude and GPT models", "3p")]
            .map { title, id in
                ["name": title, "buckets": [[
                    "id": "\(id)-weekly", "name": "Weekly Limit Remaining",
                    "window": "weekly", "remaining_fraction": 1.0,
                ]]]
            }
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "SUCCESS", "command": ["name": "usage", "data": ["groups": groups]],
        ])
        let report = try #require(String(bytes: data, encoding: .utf8))
        let fixture = try self.scopedPrintFixture(body: """
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """)
        defer { self.removeFixture(fixture.directory) }
        let environment = self.tokenOnlyAccountEnv(email: "starter@example.com")
            .merging(fixture.environment) { _, value in value }
        let result = try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
            binary: fixture.binary.path,
            environment: environment,
            dataLoader: self.userinfoLoader(mapping: ["scoped-access-token": "starter@example.com"]))
        let windows = try #require(result.usage.extraRateWindows)
        #expect(windows.count == 2)
        #expect(windows.map(\.window.windowMinutes) == [10080, 10080])
        #expect(windows.map(\.window.remainingPercent) == [100, 100])
        #expect(result.usage.identity?.accountEmail == "starter@example.com")
    }

    @Test(arguments: [false, true])
    func `userinfo cancellation propagates without persisting credentials`(urlCancellation: Bool) async throws {
        let fixture = try self.scopedPrintFixture(body: """
        /bin/cat <<'REPORT'
        \(self.reportJSON())
        REPORT
        """)
        defer { self.removeFixture(fixture.directory) }
        let environment = self.tokenOnlyAccountEnv(email: "scoped@example.com")
            .merging(fixture.environment) { _, value in value }
        await #expect(throws: CancellationError.self) {
            try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
                binary: fixture.binary.path,
                environment: environment,
                dataLoader: { _ in
                    if urlCancellation { throw URLError(.cancelled) }
                    throw CancellationError()
                },
                credentialsUpdateHandler: { _ in Issue.record("Cancelled fetch must not persist") })
        }
    }

    @Test
    func `refreshed id token cannot relabel a verified account on the next fetch`() async throws {
        let replacement = AntigravityAgyFileTokenPayload(
            token: .init(
                accessToken: "scoped-access-token",
                tokenType: "Bearer",
                refreshToken: "refresh",
                expiry: "2030-01-01T00:00:00Z"),
            authMethod: "consumer",
            idToken: GeminiAPITestHelpers.makeIDToken(email: "sibling@example.com"))
        let payloadData = try JSONEncoder().encode(replacement)
        let payload = try #require(String(bytes: payloadData, encoding: .utf8))
        let fixture = try self.scopedPrintFixture(body: """
        /bin/cat > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" <<'TOKEN'
        \(payload)
        TOKEN
        /bin/cat <<'REPORT'
        \(self.reportJSON())
        REPORT
        """)
        defer { self.removeFixture(fixture.directory) }
        let environment = self.accountEnv(email: "scoped@example.com")
            .merging(fixture.environment) { _, value in value }
        await #expect(throws: AntigravityScopedStagingError.identityUnverifiable) {
            try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
                binary: fixture.binary.path,
                environment: environment,
                dataLoader: self.userinfoLoader(mapping: ["scoped-access-token": "scoped@example.com"]),
                credentialsUpdateHandler: { _ in Issue.record("Conflicting identity must not persist") })
        }
    }

    @Test
    func `scoped print runs agy against the staged private home`() async throws {
        let report = try self.reportJSON()
        let fixture = try self.scopedPrintFixture(body: """
        [ -n "${SSH_TTY:-}" ] || exit 21
        [ -z "${ANTIGRAVITY_OAUTH_CREDENTIALS_JSON+x}" ] || exit 22
        [ -z "${LEAKED_PARENT_SECRET+x}" ] || exit 23
        [ "$HOME" != "/Users/ambient" ] || exit 26
        [ -f "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ] || exit 24
        /usr/bin/grep -q 'scoped-access-token' "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" || exit 25
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """)
        defer { self.removeFixture(fixture.directory) }

        var environment = self.accountEnv(email: "scoped@example.com")
        environment.merge(fixture.environment) { _, new in new }
        environment["HOME"] = "/Users/ambient"
        environment["LEAKED_PARENT_SECRET"] = "must-not-reach-child"

        let result = try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
            binary: fixture.binary.path,
            environment: environment,
            dataLoader: self.userinfoLoader(mapping: ["scoped-access-token": "scoped@example.com"]))

        #expect(result.usage.identity?.accountEmail == "scoped@example.com")
        #expect(abs((result.usage.primary?.usedPercent ?? -1) - 40) < 0.001)
    }

    @Test
    func `scoped print rejects a report when the effective token belongs to another account`() async throws {
        let report = try self.reportJSON()
        // Simulate agy refreshing the staged grant into a different account's
        // token: the id_token still claims the selected account, but the access
        // token that made the API calls resolves to a donor account.
        let fixture = try self.scopedPrintFixture(body: """
        /usr/bin/sed -i '' 's/scoped-access-token/donor-access-token/' \
            "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """)
        defer { self.removeFixture(fixture.directory) }

        var environment = self.accountEnv(email: "scoped@example.com")
        environment.merge(fixture.environment) { _, new in new }

        let persisted = LockIsolated<AntigravityOAuthCredentials?>(nil)
        await #expect(throws: AntigravityStatusProbeError.accountMismatch(
            expected: "scoped@example.com", found: "donor@example.com"))
        {
            try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
                binary: fixture.binary.path,
                environment: environment,
                dataLoader: self.userinfoLoader(mapping: [
                    "scoped-access-token": "scoped@example.com",
                    "donor-access-token": "donor@example.com",
                ]),
                credentialsUpdateHandler: { persisted.setValue($0) })
        }
        // A rejected identity must never reach the saved-account updater.
        #expect(persisted.value == nil)
    }

    @Test
    func `scoped print persists refreshed staged credentials for the next run`() async throws {
        let report = try self.reportJSON()
        // Simulate agy refreshing an expired staged grant: it rewrites the
        // staged token file with fresh tokens and expiry before printing.
        let firstFixture = try self.scopedPrintFixture(body: """
        TOKEN_FILE="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
        ! /usr/bin/grep -q '"id_token"' "$TOKEN_FILE" || exit 30
        /usr/bin/sed -i '' \
            -e 's/scoped-access-token/refreshed-access-token/' \
            -e 's/"refresh_token":"refresh"/"refresh_token":"refreshed-refresh"/' \
            -e 's/"expiry":"[^"]*"/"expiry":"2030-01-01T00:00:00Z"/' \
            "$TOKEN_FILE"
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """)
        defer { self.removeFixture(firstFixture.directory) }

        var environment = self.expiredAccountEnv(email: "scoped@example.com")
        environment.merge(firstFixture.environment) { _, new in new }

        let persisted = LockIsolated<AntigravityOAuthCredentials?>(nil)
        let result = try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
            binary: firstFixture.binary.path,
            environment: environment,
            dataLoader: self.userinfoLoader(mapping: ["refreshed-access-token": "scoped@example.com"]),
            credentialsUpdateHandler: { persisted.setValue($0) })
        #expect(result.usage.identity?.accountEmail == "scoped@example.com")

        let updated = try #require(persisted.value)
        #expect(updated.accessToken == "refreshed-access-token")
        #expect(updated.refreshToken == "refreshed-refresh")
        #expect(updated.expiryDate == Date(timeIntervalSince1970: 1_893_456_000))

        // A second refresh stages the persisted credentials, so it must start
        // from the refreshed token — not the expired grant that was staged first.
        let secondTokenValue = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: updated)
        var secondEnvironment = [
            AntigravityOAuthCredentialsStore.environmentCredentialsKey: secondTokenValue,
        ]
        let secondFixture = try self.scopedPrintFixture(body: """
        TOKEN_FILE="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
        /usr/bin/grep -q 'refreshed-access-token' "$TOKEN_FILE" || exit 31
        ! /usr/bin/grep -q 'scoped-access-token' "$TOKEN_FILE" || exit 32
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """)
        defer { self.removeFixture(secondFixture.directory) }
        secondEnvironment.merge(secondFixture.environment) { _, new in new }

        let secondResult = try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
            binary: secondFixture.binary.path,
            environment: secondEnvironment,
            dataLoader: self.userinfoLoader(mapping: ["refreshed-access-token": "scoped@example.com"]))
        #expect(secondResult.usage.identity?.accountEmail == "scoped@example.com")
    }

    @Test
    func `scoped print attributes token-only credentials after userinfo match`() async throws {
        let report = try self.reportJSON()
        let fixture = try self.scopedPrintFixture(body: """
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """)
        defer { self.removeFixture(fixture.directory) }

        var environment = self.tokenOnlyAccountEnv(email: "scoped@example.com")
        environment.merge(fixture.environment) { _, new in new }

        let result = try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
            binary: fixture.binary.path,
            environment: environment,
            dataLoader: self.userinfoLoader(mapping: ["scoped-access-token": "scoped@example.com"]))
        #expect(result.usage.identity?.accountEmail == "scoped@example.com")
    }

    @Test
    func `scoped print rejects a report when the effective account cannot be verified`() async throws {
        let report = try self.reportJSON()
        let fixture = try self.scopedPrintFixture(body: """
        /bin/cat <<'REPORT'
        \(report)
        REPORT
        """)
        defer { self.removeFixture(fixture.directory) }

        var environment = self.accountEnv(email: "scoped@example.com")
        environment.merge(fixture.environment) { _, new in new }

        await #expect(throws: AntigravityScopedStagingError.identityUnverifiable) {
            try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
                binary: fixture.binary.path,
                environment: environment,
                dataLoader: self.userinfoLoader(mapping: [:]))
        }
    }

    @Test
    func `scoped print refuses undecodable injected credentials without spawning`() async throws {
        let fixture = try self.scopedPrintFixture(body: "echo invoked > \"$(dirname \"$0\")/invoked\"; exit 19")
        defer { self.removeFixture(fixture.directory) }
        var environment = fixture.environment
        environment[AntigravityOAuthCredentialsStore.environmentCredentialsKey] = "malformed"

        await #expect(throws: AntigravityScopedStagingError.credentialsMissingRequiredFields) {
            try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
                binary: fixture.binary.path, environment: environment)
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("invoked").path))
    }

    @Test
    func `scoped print maps stderr to a classified failure`() async throws {
        let fixture = try self.scopedPrintFixture(body: """
        /bin/cat >&2 <<'STDERR'
        Eligibility check failed: account does not support Google ToS
        STDERR
        exit 1
        """)
        defer { self.removeFixture(fixture.directory) }
        var environment = self.accountEnv(email: "scoped@example.com")
        environment.merge(fixture.environment) { _, new in new }

        await #expect(throws: AntigravityStatusProbeError.cliReportFailed(
            .exited(code: 1, reason: .ineligible)))
        {
            try await AntigravityCLIHTTPSFetchStrategy().fetchScopedPrintUsage(
                binary: fixture.binary.path, environment: environment)
        }
    }
    #endif

    // MARK: - Helpers

    private func credentials(email: String) -> AntigravityOAuthCredentials {
        AntigravityOAuthCredentials(
            accessToken: "scoped-access-token",
            refreshToken: "refresh",
            expiryDate: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: email),
            email: email)
    }

    private func accountEnv(email: String) -> [String: String] {
        guard let value = try? AntigravityOAuthCredentialsStore.tokenAccountValue(
            for: self.credentials(email: email))
        else { return [:] }
        return [AntigravityOAuthCredentialsStore.environmentCredentialsKey: value]
    }

    private func expiredAccountEnv(email: String) -> [String: String] {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "scoped-access-token",
            refreshToken: "refresh",
            expiryDate: Date(timeIntervalSince1970: 1_000_000),
            email: email)
        guard let value = try? AntigravityOAuthCredentialsStore.tokenAccountValue(
            for: credentials)
        else { return [:] }
        return [AntigravityOAuthCredentialsStore.environmentCredentialsKey: value]
    }

    private func tokenOnlyAccountEnv(email: String) -> [String: String] {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "scoped-access-token",
            refreshToken: "refresh",
            expiryDate: Date().addingTimeInterval(3600),
            email: email)
        guard let value = try? AntigravityOAuthCredentialsStore.tokenAccountValue(
            for: credentials)
        else { return [:] }
        return [AntigravityOAuthCredentialsStore.environmentCredentialsKey: value]
    }

    private func makeContext(
        sourceMode: ProviderSourceMode = .auto,
        selected: Bool = false,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        var effectiveEnv = env
        effectiveEnv["HOME"] = effectiveEnv["HOME"] ?? FileManager.default.temporaryDirectory.path
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: effectiveEnv,
            settings: nil,
            fetcher: UsageFetcher(environment: effectiveEnv),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: selected ? UUID() : nil,
            persistsCLISessions: false)
    }

    private func makeUsage(email: String?) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private func removeFixture(_ directory: URL) {
        let recordedHome = directory.appendingPathComponent("scoped-home")
        if let home = try? String(contentsOf: recordedHome, encoding: .utf8), !home.isEmpty {
            #expect(!FileManager.default.fileExists(atPath: home))
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func reportJSON() throws -> String {
        let report: [String: Any] = [
            "status": "SUCCESS",
            "response": "Synthetic quota report",
            "command": [
                "name": "usage",
                "data": [
                    "groups": [[
                        "name": "Gemini Models",
                        "buckets": [[
                            "id": "gemini-5h",
                            "name": "Five Hour Limit Remaining",
                            "window": "5h",
                            "remaining_fraction": 0.6,
                        ]],
                    ]],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: report)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    #if os(macOS)
    private func scopedPrintFixture(body: String, version: String? = "1.2.7") throws
        -> (directory: URL, binary: URL, environment: [String: String])
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("agy")
        var script = "#!/bin/sh\nset -eu\n"
        if let version {
            script += "if [ \"${1:-}\" = --version ]; then echo \"\(version)\"; exit 0; fi\n"
        }
        script += #"printf '%s' "$HOME" > "$(dirname "$0")/scoped-home""# + "\n"
        try (script + body + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (directory, binary, ["PATH": "/usr/bin:/bin"])
    }
    #endif

    #if os(macOS)
    private func userinfoLoader(
        mapping: [String: String]) -> @Sendable (URLRequest) async throws -> (Data, URLResponse)
    {
        { request in
            let token = request.value(forHTTPHeaderField: "Authorization")?
                .replacingOccurrences(of: "Bearer ", with: "")
            if let token, let email = mapping[token],
               let url = request.url
            {
                let body = try JSONSerialization.data(withJSONObject: ["email": email])
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(
                url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
    }
    #endif

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
}
