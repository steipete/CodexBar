import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct ClaudeRateLimitResetCreditsTests {
    @Test
    func `web source reports resets in usage details without identifiers or cache restore`() async throws {
        let now = Self.wholeSecondNow()
        let usage = try await Self.fetchWebUsage(cedarEmber: Self.eligibleBlock([
            Self.grant(id: "grant_secret", resetsLeft: 2, endsIn: 3 * 86400, now: now),
        ]))
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)

        #expect(snapshot.primary?.usedPercent == 11)
        let row = try #require(snapshot.detailRow(label: "Limit Reset Credits"))
        #expect(row.value == "2 available")
        #expect(row.secondaryValue?.hasPrefix("Expires ") == true)
        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("grant_secret"))

        // A cached or synced copy must not bring back a reset already used on claude.ai.
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(restored.claudeResetCredits == nil)
        #expect(restored.detailRow(label: "Limit Reset Credits") == nil)
        #expect(restored.primary?.usedPercent == 11)
    }

    @Test
    func `count sums remaining resets of started unpaused unexpired grants`() throws {
        let now = Self.wholeSecondNow()
        let day: TimeInterval = 86400
        let resets = try #require(Self.parse(Self.eligibleBlock([
            Self.grant(id: "two_left", resetsLeft: 2, endsIn: 5 * day, now: now),
            Self.grant(id: "one_left", resetsLeft: 1, endsIn: day, now: now),
            Self.grant(id: "no_expiry", resetsLeft: 1, endsIn: nil, now: now),
            Self.grant(id: "gated", resetsLeft: 1, endsIn: 2 * day, now: now, usableNow: false),
            Self.grant(id: "paused", resetsLeft: 1, endsIn: day, now: now, paused: true),
            Self.grant(id: "used_up", resetsLeft: 0, endsIn: day, now: now),
            Self.grant(id: "expired", resetsLeft: 1, endsIn: -60, now: now),
            Self.grant(id: "future", resetsLeft: 1, endsIn: 9 * day, now: now, startsIn: day),
        ])))

        #expect(resets.availableExpirations(at: now) == [
            now.addingTimeInterval(day),
            now.addingTimeInterval(2 * day),
            now.addingTimeInterval(5 * day),
            now.addingTimeInterval(5 * day),
            nil,
        ])
        // A grant that starts later waits for a refresh after its start; the one-day grant expires on screen.
        #expect(resets.availableExpirations(at: now.addingTimeInterval(1.5 * day)) == [
            now.addingTimeInterval(2 * day),
            now.addingTimeInterval(5 * day),
            now.addingTimeInterval(5 * day),
            nil,
        ])
    }

    @Test
    func `rejected reset opt-in retries once without it and keeps usage windows`() async throws {
        let now = Self.wholeSecondNow()
        let block = Self.eligibleBlock([Self.grant(id: "grant_a", resetsLeft: 1, endsIn: 86400, now: now)])
        for status in [400, 403, 404, 422, 500, 503] {
            let queries = UsageRequestLog()
            let usage = try await Self.fetchWebUsage(cedarEmber: block, optInStatus: status, usageRequests: queries)
            #expect(usage.primary?.usedPercent == 11)
            #expect(usage.resetCredits == nil)
            #expect(await queries.values == ["cedar_ember=1", ""])
        }

        // A rate limit is not caused by the opt-in; retrying it would hide the limit and double the request.
        await #expect(throws: (any Error).self) {
            try await Self.fetchWebUsage(cedarEmber: block, optInStatus: 429)
        }
    }

    @Test
    func `rejected opt-in cannot replace the authenticated session cookie`() async throws {
        let cookies = UsageRequestLog()
        let fallback = Self.webTransport(cedarEmber: "null", optInStatus: 422)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/usage") {
                await cookies.append(request.value(forHTTPHeaderField: "Cookie") ?? "")
                if url.query != nil {
                    let response = try #require(HTTPURLResponse(
                        url: url,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Set-Cookie": "sessionKey=sk-ant-renewed-fixture; Path=/; Secure"]))
                    return (Data("{}".utf8), response)
                }
            }
            return try await fallback.data(for: request)
        }
        let usage = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: "sessionKey=sk-ant-fixture-token")
        }
        #expect(usage.sessionPercentUsed == 11)
        #expect(await cookies.values == ["sessionKey=sk-ant-fixture-token", "sessionKey=sk-ant-fixture-token"])
    }

    @Test(arguments: [401, 403, 429])
    func `authentication rate limit and Cloudflare failures are not retried`(status: Int) async throws {
        let queries = UsageRequestLog()
        let fallback = Self.webTransport(cedarEmber: "null", optInStatus: 200)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/usage") {
                await queries.append(url.query ?? "")
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: status == 403 ? ["cf-mitigated": "challenge"] : [:]))
                return (Data("{}".utf8), response)
            }
            return try await fallback.data(for: request)
        }
        await #expect(throws: (any Error).self) {
            try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: "sessionKey=sk-ant-fixture-token")
            }
        }
        #expect(await queries.values == ["cedar_ember=1"])
    }

    @Test
    func `OAuth card never takes resets from merged web extras`() async throws {
        let now = Self.wholeSecondNow()
        let transport = Self.webTransport(
            cedarEmber: Self.eligibleBlock([Self.grant(id: "web_grant", resetsLeft: 1, endsIn: 86400, now: now)]),
            optInStatus: 200)
        let oauthUsage = try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
        {"five_hour": {"utilization": 7}, "seven_day": {"utilization": 21}}
        """.utf8))
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            useWebExtras: true,
            manualCookieHeader: "sessionKey=sk-ant-fixture-token")
        let credentials: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
            ClaudeOAuthCredentials(
                accessToken: "fixture-access",
                refreshToken: nil,
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil)
        }
        let usage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in oauthUsage }
        // Same organization as the Web session, so the Web extras merge runs.
        let profile: @Sendable (String) async throws -> OAuthProfileResponse = { _ in
            OAuthProfileResponse(emailAddress: nil, organizationUuid: "org-123")
        }

        let snapshot = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(credentials) {
                try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(usage) {
                    try await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(profile) {
                        try await fetcher.loadLatestUsage()
                    }
                }
            }
        }

        #expect(snapshot.primary?.usedPercent == 7)
        #expect(snapshot.providerCost != nil)
        #expect(snapshot.resetCredits == nil)
    }

    @Test
    func `malformed grants are dropped without hiding valid grants or usage windows`() throws {
        let now = Self.wholeSecondNow()
        let block = Self.eligibleBlock([
            #"{"resets_left": "many", "paused": false}"#,
            #"{"resets_left": 2, "resets_total": 1, "paused": false}"#,
            #"{"resets_left": -1, "paused": false}"#,
            #"{"resets_left": 1, "resets_total": 1}"#,
            #"{"resets_left": 1, "resets_total": 1, "paused": null}"#,
            #"{"resets_left": 1, "paused": false, "ends_at": "next tuesday"}"#,
            #"{"resets_left": 1, "paused": false, "starts_at": "soon"}"#,
            #"{"resets_left": 1, "resets_total": 1, "paused": false, "starts_at": null, "ends_at": null}"#,
        ])
        let usage = try Self.parseUsage(block)

        #expect(usage.sessionPercentUsed == 12)
        #expect(usage.resetCredits?.availableExpirations(at: now) == [nil])
    }

    @Test
    func `implausibly large inventory shows nothing but keeps usage windows`() throws {
        let now = Self.wholeSecondNow()
        let limit = ClaudeLimitResetStatusResponse.maximumResets
        let atLimit = try #require(Self.parse(Self.eligibleBlock([
            Self.grant(id: "at_limit", resetsLeft: limit, endsIn: 86400, now: now),
        ])))
        #expect(atLimit.availableExpirations(at: now).count == limit)
        for grants in [
            [Self.grant(id: "one_huge", resetsLeft: limit + 1, endsIn: 86400, now: now)],
            [Self.grant(id: "max", resetsLeft: Int.max, endsIn: 86400, now: now)],
            [
                Self.grant(id: "half_a", resetsLeft: limit / 2 + 1, endsIn: 86400, now: now),
                Self.grant(id: "half_b", resetsLeft: limit / 2 + 1, endsIn: 86400, now: now),
            ],
            Array(
                repeating: Self.grant(id: "used_up", resetsLeft: 0, endsIn: 86400, now: now),
                count: ClaudeLimitResetStatusResponse.maximumGrantRecords)
                + [Self.grant(id: "started", resetsLeft: 1, endsIn: 86400, now: now)],
        ] {
            let usage = try Self.parseUsage(Self.eligibleBlock(grants))
            #expect(usage.resetCredits == nil)
            #expect(usage.sessionPercentUsed == 12)
        }

        // Grants that have not started neither count nor trip the cap.
        let withFuture = try #require(Self.parse(Self.eligibleBlock([
            Self.grant(id: "future", resetsLeft: limit + 1, endsIn: 9 * 86400, now: now, startsIn: 86400),
            Self.grant(id: "started", resetsLeft: 1, endsIn: 86400, now: now),
        ])))
        #expect(withFuture.availableExpirations(at: now) == [now.addingTimeInterval(86400)])
    }

    @Test
    func `ineligible absent or unreadable block shows nothing`() throws {
        let now = Self.wholeSecondNow()
        let grant = Self.grant(id: "grant_a", resetsLeft: 1, endsIn: 86400, now: now)
        for block in [
            #"{"eligible": false, "ineligible_reason": "surface", "grants": [\#(grant)]}"#,
            #"{"grants": [\#(grant)]}"#,
            #"{"eligible": null, "grants": [\#(grant)]}"#,
            #"{"eligible": "yes", "grants": [\#(grant)]}"#,
            Self.eligibleBlock([]),
            "null",
            "[]",
            nil,
        ] {
            let usage = try Self.parseUsage(block)
            #expect(usage.resetCredits == nil)
            #expect(usage.sessionPercentUsed == 12)
        }
    }

    @Test
    func `menu card shows one live reset section with soonest expiry first`() throws {
        let now = Self.wholeSecondNow()
        let model = try Self.model(now: now, grants: [
            Self.grant(id: "later", resetsLeft: 1, endsIn: 6 * 86400, now: now),
            Self.grant(id: "sooner", resetsLeft: 1, endsIn: 2 * 86400, now: now),
        ])

        let presentation = try #require(model.limitResetCredits)
        #expect(presentation.text == "2 available")
        #expect(presentation.expirySummaryText == "2d · 6d")
        #expect(!model.providerDetails.flatMap(\.rows).contains { $0.label == "Limit Reset Credits" })
    }

    @Test
    func `menu card omits resets once every grant has expired`() throws {
        let now = Self.wholeSecondNow()
        let model = try Self.model(
            now: now,
            grants: [Self.grant(id: "grant_a", resetsLeft: 1, endsIn: 60, now: now)],
            displayAt: now.addingTimeInterval(120))
        #expect(model.limitResetCredits == nil)
        #expect(!model.providerDetails.flatMap(\.rows).contains { $0.label == "Limit Reset Credits" })
    }

    @Test
    func `menu card retains resets when optional credits and extra usage are off`() throws {
        let now = Self.wholeSecondNow()
        let model = try Self.model(
            now: now,
            grants: [Self.grant(id: "grant_a", resetsLeft: 1, endsIn: 86400, now: now)],
            showOptionalCreditsAndExtraUsage: false)
        #expect(model.limitResetCredits?.text == "1 available")
        #expect(!model.providerDetails.flatMap(\.rows).contains { $0.label == "Limit Reset Credits" })
    }

    // MARK: - Fixtures

    @Test
    func `render synthetic Claude reset credits before and after when requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_RESET_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Self.wholeSecondNow()
        let grants = [
            Self.grant(id: "fixture_a", resetsLeft: 1, endsIn: 2 * 86400, now: now),
            Self.grant(id: "fixture_b", resetsLeft: 1, endsIn: 6 * 86400, now: now),
        ]
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, values) in [("before", [String]()), ("after", grants)] {
                let model = try Self.model(now: now, grants: values)
                let hosting = NSHostingView(rootView: UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                hosting.appearance = NSAppearance(named: .aqua)
                try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("claude-resets-\(name).png"))
            }
        }
    }

    private actor UsageRequestLog {
        var values: [String] = []

        func append(_ value: String) {
            self.values.append(value)
        }
    }

    /// Wire timestamps carry whole seconds; parse happens at the real clock.
    private static func wholeSecondNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private static func grant(
        id: String,
        resetsLeft: Int,
        endsIn: TimeInterval?,
        now: Date,
        startsIn: TimeInterval = -86400,
        paused: Bool = false,
        usableNow: Bool = true) -> String
    {
        let endsAt = endsIn.map { "\"\(Self.iso(now.addingTimeInterval($0)))\"" } ?? "null"
        return """
        {"id": "\(id)", "label": "Fixture reset", "resets_total": \(max(resetsLeft, 1)),
         "resets_left": \(resetsLeft), "starts_at": "\(Self.iso(now.addingTimeInterval(startsIn)))",
         "ends_at": \(endsAt), "clears": ["five_hour", "seven_day"], "paused": \(paused),
         "usable_now": \(usableNow)}
        """
    }

    private static func eligibleBlock(_ grants: [String]) -> String {
        #"{"eligible": true, "grants": [\#(grants.joined(separator: ","))]}"#
    }

    private static func parseUsage(_ block: String?) throws -> ClaudeWebAPIFetcher.WebUsageData {
        let field = block.map { #", "cedar_ember": \#($0)"# } ?? ""
        return try ClaudeWebAPIFetcher._parseUsageResponseForTesting(
            Data(#"{"five_hour": {"utilization": 12}\#(field)}"#.utf8))
    }

    private static func parse(_ block: String) -> ClaudeRateLimitResetCreditsSnapshot? {
        try? self.parseUsage(block).resetCredits
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func webTransport(
        cedarEmber: String,
        optInStatus: Int,
        usageRequests: UsageRequestLog? = nil) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/usage") {
                await usageRequests?.append(url.query ?? "")
            }
            // Only the opted-in usage request carries grants.
            let optedIn = url.query == "cedar_ember=1"
            let block = optedIn ? cedarEmber : "null"
            let extraUsage = #"{"is_enabled": true, "monthly_limit": 5000, "used_credits": 1003}"#
            let (status, body) = switch url.path {
            case "/api/organizations":
                (200, #"[{"uuid":"org-123","name":"Test Org","capabilities":["chat"]}]"#)
            case "/api/organizations/org-123/usage" where optedIn && optInStatus != 200:
                (optInStatus, #"{"error": "unknown query parameter"}"#)
            case "/api/organizations/org-123/usage":
                (200, #"{"five_hour": {"utilization": 11}, "extra_usage": \#(extraUsage), "cedar_ember": \#(block)}"#)
            default:
                (404, "{}")
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }

    private static func fetchWebUsage(
        cedarEmber: String,
        optInStatus: Int = 200,
        usageRequests: UsageRequestLog? = nil) async throws -> ClaudeUsageSnapshot
    {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            dataSource: .web,
            manualCookieHeader: "sessionKey=sk-ant-fixture-token")
        let transport = Self.webTransport(
            cedarEmber: cedarEmber,
            optInStatus: optInStatus,
            usageRequests: usageRequests)
        return try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await fetcher.loadLatestUsage()
        }
    }

    private static func model(
        now: Date,
        grants: [String],
        displayAt: Date? = nil,
        showOptionalCreditsAndExtraUsage: Bool = true) throws -> UsageMenuCardView.Model
    {
        let resetCredits = Self.parse(Self.eligibleBlock(grants))
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: ClaudeUsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 34,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(4 * 86400),
                resetDescription: nil),
            opus: nil,
            resetCredits: resetCredits,
            updatedAt: now,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            rawText: nil))
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptionalCreditsAndExtraUsage,
            hidePersonalInfo: false,
            usesLiveSubtitle: false,
            now: displayAt ?? now))
    }
}
