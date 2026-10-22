import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// The token cache is a process-wide single-entry actor; serialize these tests so the
/// request-sequence assertions cannot observe another test's cookie invalidating the entry.
@Suite(.serialized)
struct TraeCNProviderTests {
    private static let sampleResponse = """
    {
        "is_credits_billing": true,
        "is_dollar_usage_billing": false,
        "trial_status": { "is_eligible_for_trial": false, "is_in_trial": false },
        "usage_summary": {
            "consumed_amount": 6958.35,
            "consumption_ratio": 0.3614727272727273,
            "total_amount": 19250
        },
        "user_entitlement_pack_list": [
            {
                "display_desc": "会员 Pro+ 连续包月",
                "group_name": "会员积分",
                "group_type": 0,
                "expire_time": 1792567945,
                "next_billing_time": 1792500600,
                "status": 1,
                "usage": { "credits_amount": 2808.3488 }
            },
            {
                "display_desc": "老用户福利",
                "group_name": "用户福利",
                "group_type": 4,
                "expire_time": 1792565071,
                "next_billing_time": 0,
                "status": 0,
                "usage": { "credits_amount": 2000 }
            }
        ]
    }
    """

    @Test
    func parseEntitlementSnapshotReadsUsageSummary() throws {
        let now = Date(timeIntervalSince1970: 1_792_477_633)
        let snapshot = try TraeCNUsageFetcher.parseEntitlementSnapshot(
            from: Data(Self.sampleResponse.utf8),
            now: now)

        #expect(snapshot.creditsLimit == 19250)
        #expect(snapshot.creditsUsed == 6958.35)
        #expect(snapshot.creditsRemaining == 19250 - 6958.35)
        #expect(snapshot.planCode == "会员 Pro+ 连续包月")
        #expect(snapshot.planPeriodEnd == Date(timeIntervalSince1970: 1_792_567_945))
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func parseEntitlementSnapshotFallsBackToNextBillingTime() throws {
        let json = """
        {
            "usage_summary": { "consumed_amount": 100, "total_amount": 1000 },
            "user_entitlement_pack_list": [
                { "display_desc": "会员 Pro", "group_type": 0, "expire_time": 0, "next_billing_time": 1792500600 }
            ]
        }
        """
        let snapshot = try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data(json.utf8))
        #expect(snapshot.planPeriodEnd == Date(timeIntervalSince1970: 1_792_500_600))
    }

    @Test
    func parseEntitlementSnapshotWithoutSubscriptionPackHasNoReset() throws {
        let json = """
        {
            "usage_summary": { "consumed_amount": 100, "total_amount": 1000 },
            "user_entitlement_pack_list": [
                { "display_desc": "福利积分", "group_type": 4, "expire_time": 1792567945 }
            ]
        }
        """
        let snapshot = try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data(json.utf8))
        #expect(snapshot.planPeriodEnd == nil)
        #expect(snapshot.planCode == nil)
    }

    @Test
    func parseEntitlementSnapshotRejectsMissingSummary() {
        let json = #"{"user_entitlement_pack_list": []}"#
        #expect(throws: TraeCNUsageError.self) {
            try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func parseEntitlementSnapshotRejectsGarbage() {
        #expect(throws: TraeCNUsageError.self) {
            try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data("not json".utf8))
        }
    }

    @Test
    func jwtExpiryDateReadsExpClaim() {
        // payload {"exp": 1792507401, "iat": 1792478601}
        let payload = Data(#"{"exp":1792507401,"iat":1792478601}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let jwt = "header.\(payload).signature"
        #expect(TraeCNUsageFetcher.jwtExpiryDate(jwt) == Date(timeIntervalSince1970: 1_792_507_401))
    }

    @Test
    func jwtExpiryDateRejectsGarbage() {
        #expect(TraeCNUsageFetcher.jwtExpiryDate("not-a-jwt") == nil)
    }

    @Test
    func toUsageSnapshotMapsCreditsWindowAndDetails() throws {
        let now = Date(timeIntervalSince1970: 1_792_477_633)
        let periodEnd = Date(timeIntervalSince1970: 1_792_500_600)
        let snapshot = TraeCNUsageSnapshot(
            creditsUsed: 6958.35,
            creditsLimit: 19250,
            creditsRemaining: 12291.65,
            planCode: "会员 Pro+ 连续包月",
            planPeriodEnd: periodEnd,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()
        let primary = try #require(usage.primary)
        #expect(primary.usedPercent > 36.1 && primary.usedPercent < 36.2)
        #expect(primary.resetsAt == periodEnd)
        #expect(primary.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(usage.identity?.loginMethod == "会员 Pro+ 连续包月")
        #expect(usage.detailRow(label: "Remaining") != nil)
    }

    // MARK: Cookie consent

    @Test
    func strategyUnavailableWhenCookieSourceOff() async {
        let context = Self.context(cookieSource: .off, header: "session=abc")
        #expect(await TraeCNWebFetchStrategy().isAvailable(context) == false)
    }

    @Test
    func strategyUnavailableWhenCookieSourceAuto() async {
        // Trae CN has no browser import; a retained header must not leak into auto mode.
        let context = Self.context(cookieSource: .auto, header: "session=abc")
        #expect(await TraeCNWebFetchStrategy().isAvailable(context) == false)
    }

    @Test
    func strategyAvailableWhenManualWithHeader() async {
        let context = Self.context(cookieSource: .manual, header: "session=abc")
        #expect(await TraeCNWebFetchStrategy().isAvailable(context))
    }

    @Test
    func strategyUnavailableWhenManualWithoutHeader() async {
        let context = Self.context(cookieSource: .manual, header: nil)
        #expect(await TraeCNWebFetchStrategy().isAvailable(context) == false)
    }

    @Test
    func fetchThrowsMissingCookieWhenDisabledWithoutNetwork() async {
        // Behavior proof: with cookies off, fetch fails before any network I/O can start.
        let context = Self.context(cookieSource: .off, header: "session=abc")
        await #expect(throws: TraeCNSettingsError.self) {
            try await TraeCNWebFetchStrategy().fetch(context)
        }
    }

    @Test
    func browserSupportExemptionRequiresManualSourceWithHeader() {
        let cli = TraeCNProviderDescriptor.descriptor.cli
        let manual = Self.settings(cookieSource: .manual, header: "session=abc")
        let off = Self.settings(cookieSource: .off, header: "session=abc")
        let empty = Self.settings(cookieSource: .manual, header: nil)
        #expect(cli.isBrowserSupportExempt(sourceMode: .web, environment: nil, settings: manual))
        #expect(cli.isBrowserSupportExempt(sourceMode: .auto, environment: nil, settings: manual))
        #expect(cli.isBrowserSupportExempt(sourceMode: .web, environment: nil, settings: off) == false)
        #expect(cli.isBrowserSupportExempt(sourceMode: .web, environment: nil, settings: empty) == false)
        #expect(cli.isBrowserSupportExempt(sourceMode: .web, environment: nil, settings: nil) == false)
    }

    // MARK: Fresh settings-to-strategy path

    @MainActor
    @Test
    func freshSettingsResolveToManualAndEnableStrategy() async throws {
        let settings = testSettingsStore(suiteName: #function)
        // A fresh Trae CN configuration has no stored cookie source.
        #expect(settings.providerConfig(for: .traecn)?.cookieSource == nil)
        settings.traeCNCookieHeader = "session=fresh-cookie"

        let snapshot = try Self.snapshot(settings: settings)
        #expect(snapshot.traecn?.cookieSource == .manual)
        #expect(snapshot.traecn?.manualCookieHeader == "session=fresh-cookie")
        #expect(await TraeCNWebFetchStrategy().isAvailable(Self.context(snapshot: snapshot)))
    }

    @MainActor
    @Test
    func settingsPickerExposesManualAndOffAndOffKeepsRejecting() async throws {
        let settings = testSettingsStore(suiteName: #function)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let settingsContext = ProviderSettingsContext(
            provider: .traecn,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let implementation = TraeCNProviderImplementation()
        let picker = try #require(implementation.settingsPickers(context: settingsContext)
            .first { $0.id == "traecn-cookie-source" })
        let field = try #require(implementation.settingsFields(context: settingsContext)
            .first { $0.id == "traecn-cookie" })

        #expect(picker.options.map(\.id) == ["manual", "off"])
        #expect(picker.binding.wrappedValue == "manual")
        #expect(field.isVisible?() == true)

        // Off must keep rejecting even while a header remains stored.
        settings.traeCNCookieHeader = "session=retained-cookie"
        picker.binding.wrappedValue = "off"
        #expect(settings.traeCNCookieSource == .off)
        #expect(field.isVisible?() == false)
        let offContext = try Self.context(snapshot: Self.snapshot(settings: settings))
        #expect(await TraeCNWebFetchStrategy().isAvailable(offContext) == false)
        await #expect(throws: TraeCNSettingsError.self) {
            try await TraeCNWebFetchStrategy().fetch(offContext)
        }

        // Selecting Manual again re-enables the strategy for the same cookie.
        picker.binding.wrappedValue = "manual"
        #expect(settings.traeCNCookieSource == .manual)
        #expect(field.isVisible?() == true)
        let manualContext = try Self.context(snapshot: Self.snapshot(settings: settings))
        #expect(await TraeCNWebFetchStrategy().isAvailable(manualContext))
    }

    // MARK: Behavior proof (request log)

    @MainActor
    @Test
    func enabledFetchExchangesTokenThenReusesCachedJWT() async throws {
        let settings = testSettingsStore(suiteName: #function)
        settings.traeCNCookieHeader = "session=account-a-\(UUID().uuidString)"
        let recorder = TraeCNRequestRecorder()
        let strategy = TraeCNWebFetchStrategy(transport: Self.transport(recorder: recorder))
        let context = try Self.context(snapshot: Self.snapshot(settings: settings))

        _ = try await strategy.fetch(context)
        #expect(recorder.snapshot().map(\.path) == [
            "/cloudide/api/v3/common/GetUserToken",
            "/trae/api/v2/pay/user_current_entitlement_list",
        ])

        // The cached JWT removes the token exchange from the second refresh.
        _ = try await strategy.fetch(context)
        #expect(recorder.snapshot().map(\.path) == [
            "/cloudide/api/v3/common/GetUserToken",
            "/trae/api/v2/pay/user_current_entitlement_list",
            "/trae/api/v2/pay/user_current_entitlement_list",
        ])
        print("[behavior proof] enabled + cached JWT:\n\(recorder.sanitizedLog())")
    }

    @MainActor
    @Test
    func disablingConsentAfterJWTWarmupPerformsZeroNetworkIO() async throws {
        let settings = testSettingsStore(suiteName: #function)
        settings.traeCNCookieHeader = "session=account-a-\(UUID().uuidString)"
        let recorder = TraeCNRequestRecorder()
        let strategy = TraeCNWebFetchStrategy(transport: Self.transport(recorder: recorder))

        _ = try await strategy.fetch(Self.context(snapshot: Self.snapshot(settings: settings)))
        #expect(recorder.snapshot().count == 2)

        settings.traeCNCookieSource = .off
        let offContext = try Self.context(snapshot: Self.snapshot(settings: settings))
        await #expect(throws: TraeCNSettingsError.self) {
            try await strategy.fetch(offContext)
        }
        // No token exchange and no entitlement request once consent is off, even with a live cached JWT.
        #expect(recorder.snapshot().count == 2)
        print("[behavior proof] cached JWT, then cookies off (log unchanged):\n\(recorder.sanitizedLog())")
    }

    @MainActor
    @Test
    func swappingAccountCookieDoesNotReuseCachedJWT() async throws {
        let settings = testSettingsStore(suiteName: #function)
        let cookieA = "session=account-a-\(UUID().uuidString)"
        let cookieB = "session=account-b-\(UUID().uuidString)"
        settings.traeCNCookieHeader = cookieA
        let recorder = TraeCNRequestRecorder()
        let strategy = TraeCNWebFetchStrategy(transport: Self.transport(recorder: recorder))

        _ = try await strategy.fetch(Self.context(snapshot: Self.snapshot(settings: settings)))
        let warmedEntries = recorder.snapshot()
        #expect(warmedEntries.count == 2)
        #expect(warmedEntries.last?.authorization == "Cloud-IDE-JWT token-for-a")

        settings.traeCNCookieHeader = cookieB
        _ = try await strategy.fetch(Self.context(snapshot: Self.snapshot(settings: settings)))
        let entries = recorder.snapshot()
        #expect(entries.count == 4)

        // Account B exchanges its own token and never presents account A's cached JWT.
        let accountBEntries = entries.filter { $0.cookie.contains("account-b") }
        #expect(accountBEntries.map(\.path) == [
            "/cloudide/api/v3/common/GetUserToken",
            "/trae/api/v2/pay/user_current_entitlement_list",
        ])
        #expect(accountBEntries.allSatisfy { $0.authorization != "Cloud-IDE-JWT token-for-a" })
        #expect(accountBEntries.last?.authorization == "Cloud-IDE-JWT token-for-b")
        print("[behavior proof] account cookie swapped mid-session:\n\(recorder.sanitizedLog())")
    }

    private static func settings(
        cookieSource: ProviderCookieSource,
        header: String?) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot.make(traecn: TraeCNProviderSettings(
            cookieSource: cookieSource,
            manualCookieHeader: header))
    }

    @MainActor
    private static func snapshot(settings: SettingsStore) throws -> ProviderSettingsSnapshot {
        let contribution = try #require(TraeCNProviderImplementation().settingsSnapshot(
            context: ProviderSettingsSnapshotContext(
                settings: settings,
                tokenOverride: nil)))
        return ProviderSettingsSnapshot(contributions: [contribution])
    }

    private static func context(snapshot: ProviderSettingsSnapshot) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: snapshot,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func context(
        cookieSource: ProviderCookieSource,
        header: String?) -> ProviderFetchContext
    {
        self.context(snapshot: self.settings(cookieSource: cookieSource, header: header))
    }

    private static func transport(recorder: TraeCNRequestRecorder) -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            let path = try #require(request.url?.path)
            let requestURL = try #require(request.url)
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            recorder.append(TraeCNRequestRecorder.Entry(
                method: request.httpMethod ?? "",
                path: path,
                cookie: cookie,
                authorization: request.value(forHTTPHeaderField: "Authorization")))

            let body: String = if path.hasSuffix("/GetUserToken") {
                // The stub hands each account cookie its own synthetic token.
                #"{"Result":{"Token":"token-for-\#(cookie.contains("account-b") ? "b" : "a")"}}"#
            } else {
                Self.sampleResponse
            }
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }
}

private final class TraeCNRequestRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        let method: String
        let path: String
        let cookie: String
        let authorization: String?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(_ entry: Entry) {
        self.lock.withLock { self.entries.append(entry) }
    }

    func snapshot() -> [Entry] {
        self.lock.withLock { self.entries }
    }

    /// Behavior-proof diagnostics: methods and request paths only, never cookie or JWT values.
    func sanitizedLog() -> String {
        self.snapshot()
            .map { entry in
                let authorization = entry.authorization == nil ? "none" : "Cloud-IDE-JWT [redacted]"
                let cookie = entry.cookie.isEmpty ? "none" : "[redacted]"
                return "\(entry.method) \(entry.path) cookie:\(cookie) authorization:\(authorization)"
            }
            .joined(separator: "\n")
    }
}
