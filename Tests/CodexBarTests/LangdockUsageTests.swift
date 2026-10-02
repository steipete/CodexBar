import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore
#if os(macOS)
import SweetCookieKit
#endif

struct LangdockUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func response(_ plan: String) -> Data {
        Data("""
        [{"result":{"data":{"json":{"hasIncludedUsageLimits":true,"planUsage":\(plan)}}}}]
        """.utf8)
    }

    @Test
    func `session and weekly percentages retain raw values and reset dates`() throws {
        let data = Self.response("""
        {"sessionUsageLimitsEnabled":true,"sessionUsagePercent":12.5,
         "sessionResetsAt":"2026-09-25T12:00:00.123Z","weeklyUsagePercent":104.2,
         "weeklyResetsAt":"2026-09-28T12:00:00Z"}
        """)
        let usage = try LangdockUsageParser.parse(data, statusCode: 200, now: Self.now)

        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt != nil)
        #expect(usage.secondary?.usedPercent == 104.2)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt != nil)
        #expect(usage.updatedAt == Self.now)
        #expect(usage.dataConfidence == .percentOnly)
    }

    @Test
    func `disabled session leaves a genuine zero weekly value`() throws {
        let data = Self.response("""
        {"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":0}
        """)
        let usage = try LangdockUsageParser.parse(data, statusCode: 200)

        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.secondary?.resetsAt == nil)
    }

    @Test
    func `inactive session keeps genuine zero values without reviving previous reset dates`() throws {
        let previous = try LangdockUsageParser.parse(
            Self.response("""
            {"sessionUsageLimitsEnabled":true,"sessionUsagePercent":20,
             "sessionResetsAt":"2026-09-25T12:00:00Z","weeklyUsagePercent":40,
             "weeklyResetsAt":"2026-09-28T00:00:00Z"}
            """),
            statusCode: 200,
            now: Self.now.addingTimeInterval(-600))
        let current = try LangdockUsageParser.parse(
            Self.response("""
            {"sessionUsageLimitsEnabled":true,"sessionUsagePercent":0,"sessionResetsAt":null,
             "weeklyUsagePercent":0,"weeklyResetsAt":null}
            """),
            statusCode: 200,
            now: Self.now)
            .backfillingResetTimesForProvider(.langdock, from: previous)

        #expect(current.primary?.usedPercent == 0)
        #expect(current.primary?.isSyntheticPlaceholder == false)
        #expect(current.primary?.resetsAt == nil)
        #expect(current.secondary?.usedPercent == 0)
        #expect(current.secondary?.resetsAt == nil)
        #expect(current.updatedAt == Self.now)
    }

    @Test
    func `weekly only usage renders one full quota CLI metric`() throws {
        let data = Self.response("""
        {"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":0}
        """)
        let snapshot = try LangdockUsageParser.parse(data, statusCode: 200, now: Self.now)
        let card = CLICardsRenderer.makeCard(.init(
            provider: .langdock,
            snapshot: snapshot,
            credits: nil,
            source: "synthetic",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))

        #expect(card.metrics.map(\.label) == ["Weekly"])
        #expect(card.metrics.first?.remainingPercent == 100)
        #expect(card.metrics.first?.resetText == nil)
    }

    @Test
    func `missing plan is a valid absence of included limits`() throws {
        let data = Data("""
        [{"result":{"data":{"json":{"hasIncludedUsageLimits":false}}}}]
        """.utf8)
        let usage = try LangdockUsageParser.parse(data, statusCode: 200)

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.details.first?.rows.first?.value == "No included usage limits available")
    }

    @Test(arguments: [
        #"{"sessionUsageLimitsEnabled":true,"weeklyUsagePercent":4}"#,
        #"{"sessionUsageLimitsEnabled":true,"sessionUsagePercent":"5","weeklyUsagePercent":4}"#,
        #"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":"4"}"#,
        #"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":4,"weeklyResetsAt":"tomorrow"}"#,
    ])
    func `missing or malformed expected fields fail instead of becoming zero`(plan: String) {
        #expect(throws: LangdockUsageError.self) {
            try LangdockUsageParser.parse(Self.response(plan), statusCode: 200)
        }
    }

    @Test(arguments: [
        #"[]"#,
        #"[{},{}]"#,
        #"[{"result":{"data":null}}]"#,
        #"[{"error":{}}]"#,
        #"[{"error":{"json":{"data":{}}}}]"#,
        #"[{"error":{"json":{"data":{"code":403}}}}]"#,
    ])
    func `malformed envelopes and incomplete trpc errors are not successful empty usage`(response: String) {
        #expect(throws: LangdockUsageError.invalidResponse) {
            try LangdockUsageParser.parse(Data(response.utf8), statusCode: 200)
        }
    }

    @Test
    func `trpc and HTTP denials are distinct from missing limits`() {
        let forbidden = Data("""
        [{"error":{"json":{"data":{"code":"FORBIDDEN"}}}}]
        """.utf8)
        #expect(throws: LangdockUsageError.forbidden) {
            try LangdockUsageParser.parse(forbidden, statusCode: 200)
        }
        #expect(throws: LangdockUsageError.unauthorized) {
            try LangdockUsageParser.parse(Data(), statusCode: 401)
        }
        #expect(throws: LangdockUsageError.httpStatus(429)) {
            try LangdockUsageParser.parse(Data(), statusCode: 429)
        }
    }

    @Test
    func `profile ID persists in Langdock provider config`() throws {
        var config = ProviderConfig(id: .langdock)
        config.langdockEdgeProfileID = "/synthetic/Edge/Profile 2"
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.langdockEdgeProfileID == "/synthetic/Edge/Profile 2")
        #expect(LangdockProviderDescriptor.descriptor.metadata.defaultEnabled == false)
        #expect(LangdockProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .web])
    }

    @MainActor
    @Test
    func `cached Langdock usage is visible only for its selected profile`() {
        let settings = testSettingsStore(suiteName: "Langdock-profile-scope", userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let firstProfile = "/synthetic/Edge/Profile 1"
        store.snapshots[.langdock] = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            langdockSessionOwner: LangdockSessionOwner(
                profileID: firstProfile,
                cookieHeader: "auth_token=synthetic-one"),
            updatedAt: Self.now).withIdentity(ProviderIdentitySnapshot(
            providerID: .langdock,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Edge profile",
            accountID: firstProfile))

        #expect(store.snapshot(for: .langdock) == nil)
        settings.updateProviderConfig(provider: .langdock) { $0.langdockEdgeProfileID = firstProfile }
        #expect(store.snapshot(for: .langdock)?.secondary?.usedPercent == 25)
        settings.updateProviderConfig(provider: .langdock) {
            $0.langdockEdgeProfileID = "/synthetic/Edge/Profile 2"
        }
        #expect(store.snapshot(for: .langdock) == nil)
    }

    @Test
    func `unscoped failures cannot preserve usage without a confirmed session owner`() {
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.httpStatus(503), hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.httpStatus(429), hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.unauthorized, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.profileUnavailable, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.profileUnreadable, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.browserAccessPaused, hadPriorData: true))
    }

    @MainActor
    @Test(ProviderTransportRegressionFixtures())
    func `a successful response without plan usage removes previous menu bars`() async throws {
        try await ProviderTransportRegressionSupport.withStore(provider: .langdock, hasPriorData: false) { store, _ in
            let profileID = "/synthetic/Edge/Default"
            store.settings.updateProviderConfig(provider: .langdock) {
                $0.source = .web
                $0.langdockEdgeProfileID = profileID
            }
            let previous = try Self.ownedSnapshot(profileID: profileID)
            store.snapshots[.langdock] = previous
            store.lastKnownResetSnapshots[.langdock] = previous
            #expect(store.menuCardModel(for: .langdock, now: Self.now).metrics.count == 2)

            let owner = try #require(previous.langdockSessionOwner)
            let current = try LangdockUsageParser.parse(
                Self.response("null"), statusCode: 200, now: Self.now)
                .withIdentity(previous.identity)
                .withLangdockSessionOwner(owner)
            store._test_providerFetchOutcomeOverride = { _ in
                ProviderFetchOutcome(result: .success(ProviderFetchResult(
                    usage: current,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "synthetic",
                    strategyID: "langdock.synthetic",
                    strategyKind: .web)), attempts: [])
            }

            await store.refreshProvider(.langdock, allowDisabled: true)

            let published = try #require(store.snapshot(for: .langdock))
            #expect(published.primary == nil)
            #expect(published.secondary == nil)
            #expect(published.updatedAt == Self.now)
            #expect(store.lastKnownResetSnapshots[.langdock]?.primary == nil)
            #expect(store.lastKnownResetSnapshots[.langdock]?.secondary == nil)
            #expect(published.details.first?.rows.first?.value == "No included usage limits available")
            #expect(store.menuCardModel(for: .langdock, now: Self.now).metrics.isEmpty)
            #expect(store.error(for: .langdock) == nil)
        }
    }

    @MainActor
    @Test(ProviderTransportRegressionFixtures())
    func `a confirmed session outage shows the error and original capture age with retained bars`() async throws {
        try await ProviderTransportRegressionSupport.withStore(provider: .langdock, hasPriorData: false) { store, _ in
            let profileID = "/synthetic/Edge/Default"
            store.settings.updateProviderConfig(provider: .langdock) {
                $0.source = .web
                $0.langdockEdgeProfileID = profileID
            }
            store.settings.usageBarsShowUsed = true
            let previous = try Self.ownedSnapshot(profileID: profileID)
            store.snapshots[.langdock] = previous
            store.lastKnownResetSnapshots[.langdock] = previous
            let failure = LangdockFetchError(
                owner: previous.langdockSessionOwner,
                underlyingError: LangdockUsageError.httpStatus(503))
            store._test_providerFetchOutcomeOverride = { _ in
                ProviderFetchOutcome(result: .failure(failure), attempts: [])
            }

            await store.refreshProvider(.langdock, allowDisabled: true)

            #expect(store.snapshot(for: .langdock)?.updatedAt == previous.updatedAt)
            #expect(store.lastKnownResetSnapshots[.langdock]?.updatedAt == previous.updatedAt)
            #expect(store.error(for: .langdock) == failure.localizedDescription)
            let model = store.menuCardModel(for: .langdock, now: Self.now)
            #expect(model.metrics.map(\.percent) == [20, 40])
            #expect(model.subtitleText == failure.localizedDescription)
            #expect(model.lastKnownUsageText == LastKnownUsagePresentation.message(
                capturedAt: previous.updatedAt, now: Self.now))
        }
    }

    private static func ownedSnapshot(profileID: String) throws -> UsageSnapshot {
        let owner = try #require(LangdockSessionOwner(
            profileID: profileID,
            cookieHeader: "auth_token=synthetic-one"))
        return try LangdockUsageParser.parse(
            Self.response("""
            {"sessionUsageLimitsEnabled":true,"sessionUsagePercent":20,
             "sessionResetsAt":"2026-09-25T12:00:00Z","weeklyUsagePercent":40,
             "weeklyResetsAt":"2026-09-28T00:00:00Z"}
            """),
            statusCode: 200,
            now: Self.now.addingTimeInterval(-600))
            .withIdentity(ProviderIdentitySnapshot(
                providerID: .langdock,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Edge profile",
                accountID: profileID))
            .withLangdockSessionOwner(owner)
    }

    #if os(macOS)
    @Test
    func `profile discovery separates permission errors from absent stores`() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        let profile = home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default").path

        #expect(BrowserDetection.selectedChromiumProfileAccessIssue(
            profileID: profile,
            browser: .edge,
            homeDirectories: [home],
            listDirectory: { _ in throw POSIXError(.EPERM) }) == .accessDenied)
        #expect(BrowserDetection.selectedChromiumProfileAccessIssue(
            profileID: profile,
            browser: .edge,
            homeDirectories: [home],
            listDirectory: { _ in throw POSIXError(.ENOENT) }) == nil)
        #expect(BrowserDetection.selectedChromiumProfileAccessIssue(
            profileID: "/other/path/Default",
            browser: .edge,
            homeDirectories: [home],
            listDirectory: { _ in throw POSIXError(.EPERM) }) == nil)
    }

    private static func store(_ profileID: String, kind: BrowserCookieStoreKind) -> BrowserCookieStore {
        BrowserCookieStore(
            browser: .edge,
            profile: BrowserProfile(id: profileID, name: URL(fileURLWithPath: profileID).lastPathComponent),
            kind: kind,
            label: "Synthetic Edge",
            databaseURL: URL(fileURLWithPath: profileID).appendingPathComponent("Cookies"))
    }

    private static func cookie(
        domain: String,
        scope: BrowserCookieScope,
        name: String,
        value: String,
        path: String = "/") -> BrowserCookieRecord
    {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: Date(timeIntervalSinceNow: 3600),
            isSecure: true,
            isHTTPOnly: true,
            scope: scope)
    }

    @Test
    func `only the selected profile store is chosen even if another comes first`() throws {
        let other = Self.store("/synthetic/Edge/Profile 1", kind: .network)
        let selectedPrimary = Self.store("/synthetic/Edge/Profile 2", kind: .primary)
        let selectedNetwork = Self.store("/synthetic/Edge/Profile 2", kind: .network)
        let stores = [other, selectedPrimary, selectedNetwork]

        #expect(try LangdockEdgeCookieImporter.selectedStore(
            profileID: selectedNetwork.profile.id,
            from: stores) == selectedNetwork)
        #expect(throws: LangdockUsageError.profileUnavailable) {
            try LangdockEdgeCookieImporter.selectedStore(profileID: "/synthetic/Edge/Profile 3", from: stores)
        }
    }

    @Test
    func `cookies honor host and path without borrowing another domain`() throws {
        let records = [
            Self.cookie(domain: "langdock.com", scope: .domain, name: "auth_token", value: "synthetic-auth"),
            Self.cookie(domain: "app.langdock.com", scope: .hostOnly, name: "pref", value: "A"),
            Self.cookie(domain: "langdock.com", scope: .hostOnly, name: "root-only", value: "B"),
            Self.cookie(domain: "other.langdock.com", scope: .domain, name: "other", value: "C"),
            Self.cookie(
                domain: "app.langdock.com",
                scope: .hostOnly,
                name: "wrong-path",
                value: "D",
                path: "/settings"),
        ]
        let header = try LangdockEdgeCookieImporter.cookieHeader(from: records)

        #expect(header.contains("auth_token=synthetic-auth"))
        #expect(header.contains("pref=A"))
        #expect(!header.contains("root-only"))
        #expect(!header.contains("other="))
        #expect(!header.contains("wrong-path"))
    }

    @Test
    func `conflicting auth cookies in one profile fail closed`() {
        let records = [
            Self.cookie(domain: "langdock.com", scope: .domain, name: "auth_token", value: "synthetic-one"),
            Self.cookie(domain: "app.langdock.com", scope: .hostOnly, name: "auth_token", value: "synthetic-two"),
        ]
        #expect(throws: LangdockUsageError.sessionUnavailable) {
            try LangdockEdgeCookieImporter.cookieHeader(from: records)
        }
    }

    @Test
    func `fetch uses only the selected profile and known Langdock endpoint`() async throws {
        let selected = "/synthetic/Edge/Profile 2"
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "app.langdock.com")
            #expect(request.url?.path == "/api/trpc/usageSettings.getPersonalUsage")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "batch" })?.value == "1")
            #expect(query?.first(where: { $0.name == "input" })?.value?.contains("\"undefined\"") == true)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth_token=synthetic-selected")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.response("""
            {"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":42}
            """), response)
        }
        let usage = try await LangdockUsageFetcher.fetch(
            edgeProfileID: selected,
            timeout: 5,
            transport: transport,
            cookieHeaderProvider: { profileID in
                guard profileID == selected else { throw LangdockUsageError.profileUnavailable }
                return "auth_token=synthetic-selected"
            })

        #expect(usage.secondary?.usedPercent == 42)
        #expect(usage.identity?.accountID == selected)
    }
    #endif
}
