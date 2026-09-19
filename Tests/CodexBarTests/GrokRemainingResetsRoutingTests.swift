import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct GrokRemainingResetsRoutingTests {
    @Test
    func `oauth billing and supplemental coupons stay on captured account during auth switch`() async throws {
        let grokHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokAccountSwitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: grokHome) }
        try Self.writeAuth(
            accessToken: "token-a",
            email: "account-a@example.com",
            to: grokHome)

        let billingGate = GrokBillingGate()
        let tierAccount = LockIsolated<String?>(nil)
        let resetAccount = LockIsolated<String?>(nil)
        let resetCookie = LockIsolated<String?>(nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expectedCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [now.addingTimeInterval(172_800)],
            updatedAt: now)

        let fetchTask = Task {
            try await GrokWebFetchStrategy().fetch(
                Self.webContext(includeOptionalUsage: true, grokHome: grokHome),
                webBilling: { capturedCredentials in
                    let credentials = try capturedCredentials.get()
                    await billingGate.waitUntilReleased()
                    return GrokWebBillingResult(
                        snapshot: GrokWebBillingSnapshot(
                            usedPercent: 29,
                            resetsAt: now.addingTimeInterval(86400)),
                        sourceLabel: "grok-cli-proxy",
                        authContext: .oauth(credentials))
                },
                settingsTier: { credentials in
                    tierAccount.setValue(credentials?.email)
                    return "SuperGrok Heavy"
                },
                remainingResets: { credentials, cookieHeader, _ in
                    resetAccount.setValue(credentials?.email)
                    resetCookie.setValue(cookieHeader)
                    return GrokRemainingResetsLookupResult(
                        tokens: [],
                        snapshotTask: Task { expectedCredits })
                })
        }

        await billingGate.waitUntilStarted()
        try Self.writeAuth(
            accessToken: "token-b",
            email: "account-b@example.com",
            to: grokHome)
        let credentialsB = try GrokCredentialsStore.load(env: ["GROK_HOME": grokHome.path])
        #expect(credentialsB.email == "account-b@example.com")
        await billingGate.release()

        let result = try await fetchTask.value
        #expect(result.usage.primary?.usedPercent == 29)
        #expect(result.usage.accountEmail(for: .grok) == "account-a@example.com")
        #expect(result.usage.loginMethod(for: .grok) == "SuperGrok Heavy")
        #expect(tierAccount.value == "account-a@example.com")
        #expect(resetAccount.value == "account-a@example.com")
        #expect(resetCookie.value == nil)
        let supplementalUpdate = await result.supplementalUsageTask?.value
        guard case let .grokResetCredits(resetCredits) = supplementalUpdate else {
            Issue.record("Expected a deferred Grok reset-credit update")
            return
        }
        #expect(resetCredits == expectedCredits)
    }

    @Test
    func `web strategy reuses the cookie that won billing for coupon lookup`() async throws {
        let capturedCookie = LockIsolated<String?>(nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try await GrokWebFetchStrategy().fetch(
            Self.webContext(includeOptionalUsage: true),
            webBilling: { _ in
                GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(
                        usedPercent: 29,
                        resetsAt: now.addingTimeInterval(86400)),
                    sourceLabel: "Chrome Profile 2",
                    authContext: .cookie("sso=winning"))
            },
            settingsTier: { _ in nil },
            remainingResets: { credentials, cookieHeader, _ in
                #expect(credentials == nil)
                capturedCookie.setValue(cookieHeader)
                return GrokRemainingResetsLookupResult(
                    tokens: [
                        GrokRemainingReset(
                            tokenID: "restok_sample",
                            grantedAt: nil,
                            expiresAt: now.addingTimeInterval(172_800)),
                    ],
                    snapshotTask: nil)
            })

        #expect(capturedCookie.value == "sso=winning")
        #expect(result.usage.details.first?.rows.first?.value == "1 available")
    }

    @Test
    func `web strategy skips coupon lookup when optional usage is disabled`() async throws {
        let lookupCalled = LockIsolated(false)
        let result = try await GrokWebFetchStrategy().fetch(
            Self.webContext(includeOptionalUsage: false),
            webBilling: { _ in
                GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(usedPercent: 29, resetsAt: nil),
                    sourceLabel: "Chrome",
                    authContext: .cookie("sso=winning"))
            },
            settingsTier: { _ in nil },
            remainingResets: { _, _, _ in
                lookupCalled.setValue(true)
                return .empty
            })

        #expect(!lookupCalled.value)
        #expect(result.usage.details.isEmpty)
    }

    @Test
    func `completion-required strategy awaits deferred coupon inventory`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = now.addingTimeInterval(172_800)
        let resetCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [expiresAt],
            updatedAt: now)
        let result = try await GrokWebFetchStrategy().fetch(
            Self.webContext(
                includeOptionalUsage: true,
                requiresOptionalUsageCompleteness: true),
            webBilling: { _ in
                GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(
                        usedPercent: 29,
                        resetsAt: now.addingTimeInterval(86400)),
                    sourceLabel: "Chrome",
                    authContext: .cookie("sso=winning"))
            },
            settingsTier: { _ in nil },
            remainingResets: { _, _, _ in
                GrokRemainingResetsLookupResult(
                    tokens: [],
                    snapshotTask: Task { resetCredits })
            })

        #expect(result.usage.grokResetCredits == resetCredits)
        #expect(result.usage.details.first?.rows.first?.value == "1 available")
        #expect(result.supplementalUsageTask == nil)
    }

    @Test
    func `CLI completion-required result awaits deferred coupon inventory`() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = now.addingTimeInterval(172_800)
        let resetCredits = GrokRateLimitResetCreditsSnapshot(
            expirations: [expiresAt],
            updatedAt: now)
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(
                usedPercent: 29,
                resetsAt: now.addingTimeInterval(86400)),
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now)
        let result = await GrokCLIFetchStrategy().makeUsageResult(
            snapshot: snapshot,
            context: Self.webContext(
                includeOptionalUsage: true,
                requiresOptionalUsageCompleteness: true),
            resetLookup: GrokRemainingResetsLookupResult(
                tokens: [],
                snapshotTask: Task { resetCredits }))

        #expect(result.usage.grokResetCredits == resetCredits)
        #expect(result.usage.details.first?.rows.first?.value == "1 available")
        #expect(result.supplementalUsageTask == nil)
    }

    private static func webContext(
        includeOptionalUsage: Bool,
        requiresOptionalUsageCompleteness: Bool = false,
        grokHome: URL? = nil) -> ProviderFetchContext
    {
        let home = grokHome ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokResetRouting-\(UUID().uuidString)", isDirectory: true)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            includeOptionalUsage: includeOptionalUsage,
            requiresOptionalUsageCompleteness: requiresOptionalUsageCompleteness,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [
                "GROK_HOME": home.path,
                "GROK_CLI_PATH": home.appendingPathComponent("missing-grok").path,
                "PATH": home.path,
            ],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func writeAuth(accessToken: String, email: String, to grokHome: URL) throws {
        let auth = #"""
        {
          "https://auth.x.ai::client": {
            "key": "\#(accessToken)",
            "email": "\#(email)",
            "principal_type": "Personal"
          }
        }
        """#
        try Data(auth.utf8).write(
            to: grokHome.appendingPathComponent("auth.json"),
            options: .atomic)
    }
}

private actor GrokBillingGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        if !self.started {
            self.started = true
            let waiters = self.startWaiters
            self.startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
