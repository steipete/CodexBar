import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore
#if os(macOS)
import SweetCookieKit
#endif

@Suite(.serialized)
struct MiMoProviderTests {
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

    @Test
    func `cookie header normalizer keeps required mimo cookies`() {
        let raw = """
        curl 'https://platform.xiaomimimo.com/api/v1/balance' \
          -H 'Cookie: userId=123; api-platform_serviceToken=svc-token; ignored=value; api-platform_ph=ph-token'
        """

        let normalized = MiMoCookieHeader.normalizedHeader(from: raw)

        #expect(normalized == "api-platform_ph=ph-token; api-platform_serviceToken=svc-token; userId=123")
    }

    @Test
    func `cookie header normalizer rejects missing auth cookies`() {
        let normalized = MiMoCookieHeader.normalizedHeader(from: "Cookie: userId=123")

        #expect(normalized == nil)
    }

    @Test
    func `cookie header builder keeps mimo auth cookies from one scope`() throws {
        let cookies = try [
            self.makeCookie(
                name: "userId",
                value: "root-user",
                domain: "xiaomimimo.com",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)),
            self.makeCookie(
                name: "api-platform_serviceToken",
                value: "platform-token",
                domain: "platform.xiaomimimo.com",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
            self.makeCookie(
                name: "userId",
                value: "platform-user",
                domain: "platform.xiaomimimo.com",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
            self.makeCookie(
                name: "api-platform_ph",
                value: "platform-ph",
                domain: "platform.xiaomimimo.com",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
        ]

        let header = MiMoCookieHeader.header(from: cookies)

        #expect(header == "api-platform_ph=platform-ph; api-platform_serviceToken=platform-token; userId=platform-user")
    }

    @Test
    func `cookie header builder prefers more specific matching cookie`() throws {
        let cookies = try [
            self.makeCookie(
                name: "userId",
                value: "root-user",
                domain: "xiaomimimo.com",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
            self.makeCookie(
                name: "userId",
                value: "api-user",
                domain: "platform.xiaomimimo.com",
                path: "/api",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)),
            self.makeCookie(
                name: "api-platform_serviceToken",
                value: "platform-token",
                domain: ".xiaomimimo.com",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
            self.makeCookie(
                name: "irrelevant",
                value: "ignored",
                domain: "platform.xiaomimimo.com",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
        ]

        let header = MiMoCookieHeader.header(from: cookies)

        #expect(header == "api-platform_serviceToken=platform-token; userId=api-user")
    }

    @Test
    func `cookie header builder rejects partial path prefix matches`() throws {
        let cookies = try [
            self.makeCookie(
                name: "userId",
                value: "partial-path-user",
                domain: "platform.xiaomimimo.com",
                path: "/api/v1/bal",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
            self.makeCookie(
                name: "userId",
                value: "valid-user",
                domain: "platform.xiaomimimo.com",
                path: "/api",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)),
            self.makeCookie(
                name: "api-platform_serviceToken",
                value: "partial-path-token",
                domain: "platform.xiaomimimo.com",
                path: "/api/v1/bal",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
            self.makeCookie(
                name: "api-platform_serviceToken",
                value: "valid-token",
                domain: "platform.xiaomimimo.com",
                path: "/api",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ]

        let header = MiMoCookieHeader.header(from: cookies)

        #expect(header == "api-platform_serviceToken=valid-token; userId=valid-user")
    }

    @Test
    func `cookie header builder accepts slash terminated path prefixes`() throws {
        let cookies = try [
            self.makeCookie(
                name: "userId",
                value: "slash-user",
                domain: "platform.xiaomimimo.com",
                path: "/api/",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
            self.makeCookie(
                name: "api-platform_serviceToken",
                value: "slash-token",
                domain: "platform.xiaomimimo.com",
                path: "/api/",
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
        ]

        let header = MiMoCookieHeader.header(from: cookies)

        #expect(header == "api-platform_serviceToken=slash-token; userId=slash-user")
    }

    @Test
    func `usage snapshot exposes balance without duplicating identity`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            updatedAt: Date(timeIntervalSince1970: 1_742_771_200))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.mimoUsage?.balanceDetail == "$25.51")
        #expect(usage.loginMethod(for: .mimo) == nil)
    }

    @Test
    func `usage snapshot exposes paid and granted balance components`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            cashBalance: 20,
            giftBalance: 5.51,
            updatedAt: Date(timeIntervalSince1970: 1_742_771_200))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.mimoUsage?.balanceDetail == "$25.51 (Paid: $20.00 / Granted: $5.51)")
        #expect(usage.loginMethod(for: .mimo) == nil)
    }

    @Test
    func `usage snapshot shows token plan as primary when available`() {
        let resetDate = Date(timeIntervalSince1970: 1_778_025_599)
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            planCode: "standard",
            planPeriodEnd: resetDate,
            planExpired: false,
            tokenUsed: 10_100_158,
            tokenLimit: 200_000_000,
            tokenPercent: 0.0505,
            updatedAt: Date(timeIntervalSince1970: 1_742_771_200))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary != nil)
        #expect(abs((usage.primary?.usedPercent ?? .nan) - 5.05) < 0.0001)
        #expect(usage.primary?.resetDescription == "10,100,158 / 200,000,000 Credits")
        #expect(usage.primary?.resetsAt == resetDate)
        #expect(usage.secondary == nil)
        #expect(usage.mimoUsage?.balanceDetail == "$25.51")
        #expect(usage.loginMethod(for: .mimo) == "Standard")
    }

    @Test
    func `menu card preserves compact local summary casing`() throws {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let summary = "Local · 1.5k total · 42 sessions · stale 34d"
        let snapshot = MiMoUsageSnapshot(
            balance: 0,
            currency: "",
            planCode: summary,
            updatedAt: now)
            .toUsageSnapshot(includeBalance: false)
        let metadata = try #require(ProviderDefaults.metadata[.mimo])

        let model = Self.makeMenuCardModel(snapshot: snapshot, metadata: metadata, now: now)

        #expect(model.planText == summary)
        #expect(model.metrics.isEmpty)
    }

    @Test
    func `menu card shows balance as status text with and without token plan`() throws {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let metadata = try #require(ProviderDefaults.metadata[.mimo])
        let balanceOnly = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            cashBalance: 20,
            giftBalance: 5.51,
            updatedAt: now)
            .toUsageSnapshot()
        let withPlan = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            cashBalance: 20,
            giftBalance: 5.51,
            planCode: "standard",
            tokenUsed: 10,
            tokenLimit: 100,
            tokenPercent: 0.1,
            updatedAt: now)
            .toUsageSnapshot()

        let balanceModel = Self.makeMenuCardModel(snapshot: balanceOnly, metadata: metadata, now: now)
        let planModel = Self.makeMenuCardModel(snapshot: withPlan, metadata: metadata, now: now)

        #expect(balanceModel.metrics.first?.title == "Balance")
        #expect(balanceModel.metrics.first?.statusText == "$25.51 (Paid: $20.00 / Granted: $5.51)")
        #expect(planModel.metrics.first?.title == "Credits")
        #expect(planModel.metrics.last?.title == "Balance")
        #expect(planModel.metrics.last?.statusText == "$25.51 (Paid: $20.00 / Granted: $5.51)")
    }

    @Test
    func `usage snapshot falls back to balance when no token plan`() {
        let snapshot = MiMoUsageSnapshot(
            balance: 0,
            currency: "USD",
            planCode: nil,
            planPeriodEnd: nil,
            planExpired: false,
            tokenUsed: 0,
            tokenLimit: 0,
            tokenPercent: 0,
            updatedAt: Date(timeIntervalSince1970: 1_742_771_200))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.mimoUsage?.balanceDetail == "$0.00")
        #expect(usage.loginMethod(for: .mimo) == nil)
    }

    @Test
    func `usage snapshot persists mimo balance details`() throws {
        let usage = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            cashBalance: 20,
            giftBalance: 5.51,
            updatedAt: Date(timeIntervalSince1970: 1_742_771_200))
            .toUsageSnapshot()

        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(usage))

        #expect(decoded.primary == nil)
        #expect(decoded.mimoUsage?.balanceDetail == "$25.51 (Paid: $20.00 / Granted: $5.51)")
    }

    @Test
    func `balance does not participate in icon or switcher quota percentages`() {
        let balanceOnly = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            updatedAt: Date())
            .toUsageSnapshot()
        let withPlan = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            planCode: "standard",
            tokenUsed: 10,
            tokenLimit: 100,
            tokenPercent: 0.1,
            updatedAt: Date())
            .toUsageSnapshot()

        let balanceIcon = IconRemainingResolver.resolvedRemaining(snapshot: balanceOnly, style: .mimo)
        let planIcon = IconRemainingResolver.resolvedRemaining(snapshot: withPlan, style: .mimo)

        #expect(balanceIcon.primary == nil)
        #expect(balanceIcon.secondary == nil)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .mimo,
            snapshot: balanceOnly,
            showUsed: false) == nil)
        #expect(planIcon.primary == 90)
        #expect(planIcon.secondary == nil)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .mimo,
            snapshot: withPlan,
            showUsed: false) == 90)
    }

    @Test
    func `parses balance payload`() throws {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let json = """
        {
          "code": 0,
          "message": "",
          "data": {
            "balance": "25.51",
            "frozenBalance": null,
            "currency": "USD",
            "overdraftLimit": null
          }
        }
        """

        let snapshot = try MiMoUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.balance == 25.51)
        #expect(snapshot.currency == "USD")
        #expect(snapshot.cashBalance == nil)
        #expect(snapshot.giftBalance == nil)
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `parses paid and granted balance fields when available`() throws {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let json = """
        {
          "code": 0,
          "message": "",
          "data": {
            "balance": "50.00",
            "frozenBalance": null,
            "currency": "USD",
            "overdraftLimit": null,
            "remainingOverdraftLimit": null,
            "giftBalance": "20.00",
            "cashBalance": "30.00"
          }
        }
        """

        let snapshot = try MiMoUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.balance == 50)
        #expect(snapshot.cashBalance == 30)
        #expect(snapshot.giftBalance == 20)
        #expect(snapshot.currency == "USD")
    }

    @Test
    func `ignores malformed optional balance components`() throws {
        let json = """
        {
          "code": 0,
          "message": "",
          "data": {
            "balance": "25.51",
            "currency": "USD",
            "giftBalance": "",
            "cashBalance": "unknown"
          }
        }
        """

        let snapshot = try MiMoUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.balance == 25.51)
        #expect(snapshot.cashBalance == nil)
        #expect(snapshot.giftBalance == nil)
    }

    @Test
    func `parses token plan detail payload`() throws {
        let json = """
        {
          "code": 0,
          "message": "",
          "data": {
            "planCode": "standard",
            "currentPeriodEnd": "2026-05-04 23:59:59",
            "expired": false
          }
        }
        """

        let detail = try MiMoUsageFetcher.parseTokenPlanDetail(from: Data(json.utf8))

        #expect(detail.planCode == "standard")
        #expect(detail.expired == false)
        #expect(detail.periodEnd != nil)
    }

    @Test
    func `parses token plan usage payload`() throws {
        let json = """
        {
          "code": 0,
          "message": "",
          "data": {
            "monthUsage": {
              "percent": 0.0505,
              "items": [
                {
                  "name": "month_total_token",
                  "used": 10100158,
                  "limit": 200000000,
                  "percent": 0.0505
                }
              ]
            }
          }
        }
        """

        let usage = try MiMoUsageFetcher.parseTokenPlanUsage(from: Data(json.utf8))

        #expect(usage.used == 10_100_158)
        #expect(usage.limit == 200_000_000)
        #expect(usage.percent == 0.0505)
    }

    @Test
    func `combined snapshot merges balance and token plan`() throws {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let balanceJSON = """
        {"code":0,"message":"","data":{"balance":"25.51","currency":"USD","cashBalance":"20","giftBalance":"5.51"}}
        """
        let detailJSON = """
        {"code":0,"message":"","data":{"planCode":"standard","currentPeriodEnd":"2026-05-04 23:59:59","expired":false}}
        """
        let usageJSON = """
        {
          "code": 0,
          "message": "",
          "data": {
            "monthUsage": {
              "percent": 0.0505,
              "items": [
                {
                  "name": "month_total_token",
                  "used": 10100158,
                  "limit": 200000000,
                  "percent": 0.0505
                }
              ]
            }
          }
        }
        """

        let snapshot = try MiMoUsageFetcher.parseCombinedSnapshot(
            balanceData: Data(balanceJSON.utf8),
            tokenDetailData: Data(detailJSON.utf8),
            tokenUsageData: Data(usageJSON.utf8),
            now: now)

        #expect(snapshot.balance == 25.51)
        #expect(snapshot.currency == "USD")
        #expect(snapshot.cashBalance == 20)
        #expect(snapshot.giftBalance == 5.51)
        #expect(snapshot.planCode == "standard")
        #expect(snapshot.tokenUsed == 10_100_158)
        #expect(snapshot.tokenLimit == 200_000_000)
        #expect(snapshot.tokenPercent == 0.0505)
    }

    @Test
    func `fetch usage hits mimo balance endpoint with browser headers`() async throws {
        let registered = URLProtocol.registerClass(MiMoStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiMoStubURLProtocol.self)
            }
            MiMoStubURLProtocol.handler = nil
        }

        let lock = NSLock()
        var requestedPaths: [String] = []
        MiMoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            lock.withLock {
                requestedPaths.append(url.path)
            }
            #expect(request.value(forHTTPHeaderField: "Cookie") == "api-platform_serviceToken=svc-token; userId=123")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            #expect(request.value(forHTTPHeaderField: "x-timeZone") == "UTC+01:00")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://platform.xiaomimimo.com/#/console/balance")
            let body = """
            {
              "code": 0,
              "message": "",
              "data": {
                "balance": "25.51",
                "currency": "USD"
              }
            }
            """
            return Self.makeResponse(url: url, body: body)
        }

        let snapshot = try await MiMoUsageFetcher.fetchUsage(
            cookieHeader: "Cookie: userId=123; api-platform_serviceToken=svc-token",
            environment: ["MIMO_API_URL": "https://mimo.test/api/v1"],
            now: Date(timeIntervalSince1970: 1_742_771_200))

        #expect(snapshot.balance == 25.51)
        #expect(snapshot.currency == "USD")
        #expect(requestedPaths.contains("/api/v1/balance"))
    }

    @Test
    func `required balance failure cancels optional mimo requests promptly`() async throws {
        let optionalStarted = MiMoOptionalRequestGate()
        let transport = ProviderHTTPTransportStub { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/balance") {
                await optionalStarted.wait()
                throw URLError(.userAuthenticationRequired)
            }

            await optionalStarted.open()
            try await Task.sleep(for: .seconds(5))
            let (response, data) = try Self.makeResponse(url: #require(request.url), body: "{}")
            return (data, response)
        }

        let startedAt = ContinuousClock.now
        do {
            _ = try await MiMoUsageFetcher.fetchUsage(
                cookieHeader: "userId=123; api-platform_serviceToken=svc-token",
                environment: ["MIMO_API_URL": "https://mimo.test/api/v1"],
                session: transport)
            Issue.record("Expected required balance request to fail")
        } catch let error as URLError {
            #expect(error.code == .userAuthenticationRequired)
        }
        let elapsed = startedAt.duration(to: .now)

        #expect(elapsed < .seconds(1), "Required failure was delayed by optional requests: \(elapsed)")
    }

    @Test
    func `fetch usage treats auth redirect as login required`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let (response, data) = Self.makeResponse(url: url, body: "", statusCode: 302)
            return (data, response)
        }

        do {
            _ = try await MiMoUsageFetcher.fetchUsage(
                cookieHeader: "userId=123; api-platform_serviceToken=expired-token",
                environment: ["MIMO_API_URL": "https://mimo.test/api/v1"],
                session: transport)
            Issue.record("Expected MiMo auth redirect to require login")
        } catch MiMoUsageError.loginRequired {
            // Expected.
        }
    }
}

private actor MiMoOptionalRequestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func open() {
        self.isOpen = true
        let continuations = self.continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

extension MiMoProviderTests {
    @Test
    @MainActor
    func `provider detail plan row formats mimo as balance`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let legacyBalance = ProviderDetailView<Text>.planRow(provider: .mimo, planText: "Balance: $25.51")
            let tokenPlan = ProviderDetailView<Text>.planRow(provider: .mimo, planText: "Standard")

            #expect(legacyBalance?.label == "Balance")
            #expect(legacyBalance?.value == "$25.51")
            #expect(tokenPlan?.label == "Plan")
            #expect(tokenPlan?.value == "Standard")
        }
    }

    @Test(arguments: [UsageProvider.openrouter, .mimo])
    @MainActor
    func `menu descriptor renders balance providers without duplicate prefix`(provider: UsageProvider) throws {
        let suite = "MiMoProviderTests-menu-balance-\(provider.rawValue)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(self.makeBalanceSnapshot(provider: provider), provider: provider)

        let descriptor = MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains("Balance: $25.51"))
        #expect(!lines.contains("Balance: Balance: $25.51"))
        if provider == .mimo {
            #expect(!lines.contains(where: { $0.hasPrefix("Balance: 100%") }))
        }
    }

    @Test
    @MainActor
    func `menu descriptor renders mimo token detail without reset date`() throws {
        let suite = "MiMoProviderTests-menu-token-detail"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            planCode: "standard",
            tokenUsed: 10,
            tokenLimit: 100,
            tokenPercent: 0.1,
            updatedAt: Date(timeIntervalSince1970: 1_742_771_200))
            .toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .mimo)

        let descriptor = MenuDescriptor.build(
            provider: .mimo,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains("10 / 100 Credits"))
        #expect(!lines.contains("Resets 10 / 100 Credits"))
    }

    @Test
    func `mimo web strategy unavailable when cookie source is off`() async {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.store(
            provider: .mimo,
            cookieHeader: "api-platform_serviceToken=svc-token; userId=123",
            sourceLabel: "cached")
        defer { CookieHeaderCache.clear(provider: .mimo) }

        let strategy = MiMoWebFetchStrategy()
        let context = self.makeContext(settings: ProviderSettingsSnapshot.make(
            mimo: ProviderSettingsSnapshot.MiMoProviderSettings(
                cookieSource: .off,
                manualCookieHeader: nil)))

        let available = await strategy.isAvailable(context)

        #expect(available == false)
    }

    @Test
    func `mimo local strategy works when web cookies are disabled or invalid`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-local-strategy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.json")
        let payload: [String: Any] = [
            "sessions_scanned": 2,
            "windows": [
                "today": ["input": 100, "output": 50, "cache_read": 0, "cache_create": 0],
                "week": ["input": 100, "output": 50, "cache_read": 0, "cache_create": 0],
                "all_time": ["input": 100, "output": 50, "cache_read": 0, "cache_create": 0],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        let settings = [
            ProviderSettingsSnapshot.make(mimo: .init(cookieSource: .off, manualCookieHeader: nil)),
            ProviderSettingsSnapshot.make(
                mimo: .init(cookieSource: .manual, manualCookieHeader: "Cookie: userId=123")),
        ]

        for setting in settings {
            let context = self.makeContext(
                settings: setting,
                environment: ["MIMO_LOCAL_USAGE_PATH": file.path])
            let outcome = await MiMoProviderDescriptor.descriptor.fetchPlan.fetchOutcome(
                context: context,
                provider: .mimo)

            switch outcome.result {
            case let .success(result):
                #expect(result.sourceLabel == "local")
                #expect(result.strategyID == "mimo.local")
                #expect(result.usage.primary == nil)
                #expect(result.usage.mimoUsage == nil)
                #expect(result.usage.loginMethod(for: .mimo) == "Local · 150 today · 150 week · 150 total · 2 sessions")
            case let .failure(error):
                Issue.record("Expected local MiMo fallback, got \(error)")
            }
        }
    }

    @Test
    func `mimo malformed local cache stays available and reports its cache error`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-invalid-local-strategy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.json")
        try Data("{}".utf8).write(to: file)

        let context = self.makeContext(environment: ["MIMO_LOCAL_USAGE_PATH": file.path])
        let strategy = MiMoLocalFetchStrategy()

        #expect(await strategy.isAvailable(context))
        await #expect(throws: MiMoLocalUsageError.self) {
            try await strategy.fetch(context)
        }
    }

    @Test
    func `mimo explicit web mode does not use local fallback`() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-web-mode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.json")
        let payload: [String: Any] = [
            "updated_at": "2026-06-03T05:04:03+00:00",
            "sessions_scanned": 1,
            "windows": [
                "today": ["input": 100, "output": 50, "cache_read": 0, "cache_create": 0],
                "week": ["input": 100, "output": 50, "cache_read": 0, "cache_create": 0],
                "all_time": ["input": 100, "output": 50, "cache_read": 0, "cache_create": 0],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        let context = self.makeContext(
            sourceMode: .web,
            settings: ProviderSettingsSnapshot.make(
                mimo: .init(cookieSource: .off, manualCookieHeader: nil)),
            environment: ["MIMO_LOCAL_USAGE_PATH": file.path])
        let outcome = await MiMoProviderDescriptor.descriptor.fetchPlan.fetchOutcome(
            context: context,
            provider: .mimo)

        switch outcome.result {
        case let .success(result):
            Issue.record("Expected explicit web mode to reject local fallback, got \(result.strategyID)")
        case .failure:
            break
        }
    }

    @Test
    func `mimo manual mode does not report available from cached browser session`() async {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.store(
            provider: .mimo,
            cookieHeader: "api-platform_serviceToken=svc-token; userId=123",
            sourceLabel: "cached")
        defer { CookieHeaderCache.clear(provider: .mimo) }

        let strategy = MiMoWebFetchStrategy()
        let context = self.makeContext(settings: ProviderSettingsSnapshot.make(
            mimo: ProviderSettingsSnapshot.MiMoProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "Cookie: userId=123")))

        let available = await strategy.isAvailable(context)

        #expect(available == false)
    }

    @Test
    func `mimo manual mode rejects invalid header instead of falling back to cached session`() async {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.store(
            provider: .mimo,
            cookieHeader: "api-platform_serviceToken=svc-token; userId=123",
            sourceLabel: "cached")
        defer { CookieHeaderCache.clear(provider: .mimo) }

        let strategy = MiMoWebFetchStrategy()
        let context = self.makeContext(settings: ProviderSettingsSnapshot.make(
            mimo: ProviderSettingsSnapshot.MiMoProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "Cookie: userId=123")))

        await #expect(throws: MiMoSettingsError.invalidCookie) {
            _ = try await strategy.fetch(context)
        }
    }

    @Test
    func `mimo cookie importer surfaces safari access denial`() throws {
        let detection = BrowserDetection(
            homeDirectory: "/tmp/codexbar-mimo-browser-test",
            cacheTTL: 0,
            fileExists: { _ in false },
            directoryContents: { _ in nil })

        do {
            _ = try MiMoCookieImporter.importSessions(
                browserDetection: detection,
                loadRecords: { browser, _, _ in
                    throw BrowserCookieError.accessDenied(
                        browser: browser,
                        details: "Grant CodexBar Full Disk Access to read Safari cookies.")
                })
            Issue.record("Expected Safari access denial")
        } catch let error as MiMoSettingsError {
            #expect(error.localizedDescription.contains("Full Disk Access"))
            #expect(error.localizedDescription.contains("Safari"))
        }
    }

    @Test
    func `mimo web strategy retries imported sessions after decode failure`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        let registered = URLProtocol.registerClass(MiMoStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiMoStubURLProtocol.self)
            }
            MiMoStubURLProtocol.handler = nil
            CookieHeaderCache.clear(provider: .mimo)
        }

        CookieHeaderCache.clear(provider: .mimo)
        CookieHeaderCache.store(provider: .mimo, cookieHeader: "invalid", sourceLabel: "invalid")

        try await MiMoCookieImporter.withImportSessionsOverrideForTesting { _, _ in
            [
                .init(
                    cookieHeader: "api-platform_serviceToken=expired-token; userId=111",
                    sourceLabel: "Expired Chrome"),
                .init(
                    cookieHeader: "api-platform_serviceToken=valid-token; userId=222",
                    sourceLabel: "Active Chrome"),
            ]
        } operation: {
            let lock = NSLock()
            var requestedCookies: [String] = []
            MiMoStubURLProtocol.handler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                lock.withLock {
                    requestedCookies.append(cookie)
                }

                if cookie.contains("expired-token") {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/html"])!
                    return (response, Data("<html>login</html>".utf8))
                }

                let body = """
                {
                  "code": 0,
                  "message": "",
                  "data": {
                    "balance": "25.51",
                    "currency": "USD"
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }

            let strategy = MiMoWebFetchStrategy()
            let result = try await strategy
                .fetch(self.makeContext(environment: ["MIMO_API_URL": "https://mimo.test/api/v1"]))

            #expect(requestedCookies.count == 6)
            #expect(requestedCookies.contains(where: { $0.contains("expired-token") }))
            #expect(requestedCookies.contains(where: { $0.contains("valid-token") }))
            #expect(result.usage.mimoUsage?.balanceDetail == "$25.51")
            #expect(CookieHeaderCache.load(provider: .mimo)?.sourceLabel == "Active Chrome")
        }
    }

    @Test
    func `mimo web strategy retries safari after stale chrome auth redirect`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        let registered = URLProtocol.registerClass(MiMoStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiMoStubURLProtocol.self)
            }
            MiMoStubURLProtocol.handler = nil
            CookieHeaderCache.clear(provider: .mimo)
        }

        CookieHeaderCache.clear(provider: .mimo)
        CookieHeaderCache.store(
            provider: .mimo,
            cookieHeader: "api-platform_serviceToken=stale-chrome-token; userId=111",
            sourceLabel: "Chrome")

        try await MiMoCookieImporter.withImportSessionsOverrideForTesting { _, _ in
            [
                .init(
                    cookieHeader: "api-platform_serviceToken=stale-chrome-token; userId=111",
                    sourceLabel: "Chrome"),
                .init(
                    cookieHeader: "api-platform_serviceToken=valid-safari-token; userId=222",
                    sourceLabel: "Safari"),
            ]
        } operation: {
            let lock = NSLock()
            var requestedCookies: [String] = []
            MiMoStubURLProtocol.handler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                lock.withLock {
                    requestedCookies.append(cookie)
                }

                if cookie.contains("stale-chrome-token") {
                    return Self.makeResponse(url: url, body: "", statusCode: 302)
                }

                let body = """
                {
                  "code": 0,
                  "message": "",
                  "data": {
                    "balance": "25.51",
                    "currency": "USD"
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }

            let strategy = MiMoWebFetchStrategy()
            let result = try await strategy
                .fetch(self.makeContext(environment: ["MIMO_API_URL": "https://mimo.test/api/v1"]))

            #expect(requestedCookies.contains(where: { $0.contains("stale-chrome-token") }))
            #expect(requestedCookies.contains(where: { $0.contains("valid-safari-token") }))
            #expect(result.usage.mimoUsage?.balanceDetail == "$25.51")
            #expect(CookieHeaderCache.load(provider: .mimo)?.sourceLabel == "Safari")
        }
    }

    #if os(macOS)
    @Test
    func `mimo importer merges profile stores before validating auth cookies`() {
        let profile = BrowserProfile(id: "Default", name: "Default")
        let primaryStore = BrowserCookieStore(
            browser: .chrome,
            profile: profile,
            kind: .primary,
            label: "Chrome Default",
            databaseURL: nil)
        let networkStore = BrowserCookieStore(
            browser: .chrome,
            profile: profile,
            kind: .network,
            label: "Chrome Default (Network)",
            databaseURL: nil)
        let expires = Date(timeIntervalSince1970: 1_900_000_000)

        let sessions = MiMoCookieImporter.sessionInfos(from: [
            BrowserCookieStoreRecords(store: primaryStore, records: [
                BrowserCookieRecord(
                    domain: "platform.xiaomimimo.com",
                    name: "userId",
                    path: "/",
                    value: "123",
                    expires: expires,
                    isSecure: true,
                    isHTTPOnly: false),
            ]),
            BrowserCookieStoreRecords(store: networkStore, records: [
                BrowserCookieRecord(
                    domain: "platform.xiaomimimo.com",
                    name: "api-platform_serviceToken",
                    path: "/",
                    value: "token",
                    expires: expires,
                    isSecure: true,
                    isHTTPOnly: true),
            ]),
        ])

        #expect(sessions.count == 1)
        #expect(sessions.first?.sourceLabel == "Chrome Default")
        #expect(sessions.first?.cookieHeader == "api-platform_serviceToken=token; userId=123")
    }

    @Test
    func `mimo importer recovers firefox session restore cookies`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-session")
        defer { try? FileManager.default.removeItem(at: temp) }

        let json = """
        {
          "cookies": [
            {
              "host": ".platform.xiaomimimo.com",
              "path": "/",
              "name": "api-platform_serviceToken",
              "value": "svc-token",
              "secure": false,
              "httponly": false
            },
            {
              "host": ".xiaomimimo.com",
              "path": "/",
              "name": "userId",
              "value": "1863175063",
              "secure": false,
              "httponly": false
            },
            {
              "host": ".platform.xiaomimimo.com",
              "path": "/",
              "name": "api-platform_ph",
              "value": "ph-token",
              "secure": false,
              "httponly": false
            }
          ]
        }
        """
        try self.mozillaLZ4LiteralFile(json).write(to: backups.appendingPathComponent("recovery.jsonlz4"))

        let records = MiMoFirefoxSessionCookieImporter.records(profileDirectory: profile)
        let store = self.makeFirefoxCookieStore(profileDirectory: profile)
        let sessions = MiMoCookieImporter.sessionInfos(from: [
            BrowserCookieStoreRecords(store: store, records: records),
        ])

        #expect(sessions.map(\.cookieHeader) == [
            "api-platform_ph=ph-token; api-platform_serviceToken=svc-token; userId=1863175063",
        ])
    }

    @Test
    func `current partial firefox state does not resurrect backup credentials`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-backup")
        defer { try? FileManager.default.removeItem(at: temp) }

        let partial = """
        {"cookies":[
          {"host":".platform.xiaomimimo.com","path":"/","name":"api-platform_ph","value":"ph-token"}
        ]}
        """
        let complete = """
        {"cookies":[
          {"host":".platform.xiaomimimo.com","path":"/","name":"api-platform_serviceToken","value":"svc-token"},
          {"host":".xiaomimimo.com","path":"/","name":"userId","value":"1863175063"}
        ]}
        """
        try self.mozillaLZ4LiteralFile(partial).write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        try self.mozillaLZ4LiteralFile(complete).write(to: backups.appendingPathComponent("recovery.baklz4"))

        let records = MiMoFirefoxSessionCookieImporter.records(profileDirectory: profile)
        let store = self.makeFirefoxCookieStore(profileDirectory: profile)
        let sessions = MiMoCookieImporter.sessionInfos(from: [
            BrowserCookieStoreRecords(store: store, records: records),
        ])

        #expect(records.map(\.name) == ["api-platform_ph"])
        #expect(sessions.isEmpty)
    }

    @Test
    func `malformed current firefox state falls back to recovery backup`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-corrupt")
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data("not-jsonlz4".utf8).write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        let complete = """
        {"cookies":[
          {"host":".platform.xiaomimimo.com","path":"/","name":"api-platform_serviceToken","value":"svc-token"},
          {"host":".xiaomimimo.com","path":"/","name":"userId","value":"1863175063"}
        ]}
        """
        try self.mozillaLZ4LiteralFile(complete).write(to: backups.appendingPathComponent("recovery.baklz4"))

        let records = MiMoFirefoxSessionCookieImporter.records(profileDirectory: profile)

        #expect(Set(records.map(\.value)) == Set(["svc-token", "1863175063"]))
    }

    @Test
    func `partial firefox state does not merge persisted and stale backup credentials`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-persisted")
        defer { try? FileManager.default.removeItem(at: temp) }

        let recovery = """
        {"cookies":[
          {"host":".platform.xiaomimimo.com","path":"/","name":"api-platform_ph","value":"ph-token"}
        ]}
        """
        let backup = """
        {"cookies":[
          {"host":".platform.xiaomimimo.com","path":"/","name":"api-platform_serviceToken","value":"old-token"},
          {"host":".xiaomimimo.com","path":"/","name":"userId","value":"old-user"}
        ]}
        """
        try self.mozillaLZ4LiteralFile(recovery).write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        try self.mozillaLZ4LiteralFile(backup).write(to: backups.appendingPathComponent("recovery.baklz4"))

        let store = self.makeFirefoxCookieStore(profileDirectory: profile)
        let persisted = BrowserCookieStoreRecords(store: store, records: [
            BrowserCookieRecord(
                domain: "platform.xiaomimimo.com",
                name: "api-platform_serviceToken",
                path: "/",
                value: "current-token",
                expires: Date(timeIntervalSince1970: 1_912_064_978),
                isSecure: false,
                isHTTPOnly: false),
            BrowserCookieRecord(
                domain: "xiaomimimo.com",
                name: "userId",
                path: "/",
                value: "current-user",
                expires: Date(timeIntervalSince1970: 1_912_064_978),
                isSecure: false,
                isHTTPOnly: false),
        ])
        let resolved = MiMoCookieImporter.recordsIncludingFirefoxSessionCookies(
            from: [persisted],
            browser: .firefox,
            stores: [store])

        #expect(Set(resolved.first?.records.map(\.value) ?? []) == Set(["current-token", "current-user"]))
        #expect(MiMoCookieImporter.sessionInfos(from: resolved).map(\.cookieHeader) == [
            "api-platform_serviceToken=current-token; userId=current-user",
        ])
    }

    @Test
    func `resource limited firefox state preserves persisted credentials`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-persisted-limit")
        defer { try? FileManager.default.removeItem(at: temp) }

        var oversized = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])
        var declaredSize = UInt32(129 * 1024 * 1024).littleEndian
        withUnsafeBytes(of: &declaredSize) { oversized.append(contentsOf: $0) }
        try oversized.write(to: backups.appendingPathComponent("recovery.jsonlz4"))
        let staleBackup = """
        {"cookies":[
          {"host":".platform.xiaomimimo.com","name":"api-platform_serviceToken","value":"old-token"},
          {"host":".xiaomimimo.com","name":"userId","value":"old-user"}
        ]}
        """
        try self.mozillaLZ4LiteralFile(staleBackup)
            .write(to: backups.appendingPathComponent("recovery.baklz4"))

        let store = self.makeFirefoxCookieStore(profileDirectory: profile)
        let persisted = BrowserCookieStoreRecords(store: store, records: [
            BrowserCookieRecord(
                domain: "platform.xiaomimimo.com",
                name: "api-platform_serviceToken",
                path: "/",
                value: "current-token",
                expires: nil,
                isSecure: true,
                isHTTPOnly: true),
            BrowserCookieRecord(
                domain: "xiaomimimo.com",
                name: "userId",
                path: "/",
                value: "current-user",
                expires: nil,
                isSecure: true,
                isHTTPOnly: false),
        ])

        let resolved = MiMoCookieImporter.recordsIncludingFirefoxSessionCookies(
            from: [persisted],
            browser: .firefox,
            stores: [store])

        #expect(Set(resolved.first?.records.map(\.value) ?? []) == Set(["current-token", "current-user"]))
    }

    @Test
    func `mimo importer recovers session cookies when firefox query returns no rows`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-empty-store")
        defer { try? FileManager.default.removeItem(at: temp) }

        let json = """
        {
          "cookies": [
            {
              "host": ".platform.xiaomimimo.com",
              "path": "/",
              "name": "api-platform_serviceToken",
              "value": "svc-token"
            },
            {"host": ".xiaomimimo.com", "path": "/", "name": "userId", "value": "1863175063"}
          ]
        }
        """
        try self.mozillaLZ4LiteralFile(json).write(to: backups.appendingPathComponent("recovery.jsonlz4"))

        let store = self.makeFirefoxCookieStore(
            profileDirectory: profile,
            profileID: "opaque-firefox-profile")
        let resolved = MiMoCookieImporter.recordsIncludingFirefoxSessionCookies(
            from: [],
            browser: .firefox,
            stores: [store])

        #expect(resolved.count == 1)
        #expect(resolved.first?.store.profile.id == "opaque-firefox-profile")
        #expect(MiMoCookieImporter.sessionInfos(from: resolved).map(\.cookieHeader) == [
            "api-platform_serviceToken=svc-token; userId=1863175063",
        ])
    }

    @Test
    func `mimo import path checks firefox stores after an empty domain query`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-import")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = self.makeFirefoxCookieStore(profileDirectory: profile)
        let profilesRoot = profile.deletingLastPathComponent()
        let json = """
        {
          "cookies": [
            {
              "host": ".platform.xiaomimimo.com",
              "path": "/",
              "name": "api-platform_serviceToken",
              "value": "svc-token"
            },
            {"host": ".xiaomimimo.com", "path": "/", "name": "userId", "value": "1863175063"}
          ]
        }
        """
        try self.mozillaLZ4LiteralFile(json).write(to: backups.appendingPathComponent("recovery.jsonlz4"))

        let firefoxAppPath = "/Applications/\(Browser.firefox.appBundleName).app"
        let detection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { path in
                path == firefoxAppPath || path == profilesRoot.path || path == store.databaseURL?.path
            },
            directoryContents: { path in
                path == profilesRoot.path ? [profile.lastPathComponent] : nil
            },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        var queriedFirefoxStores = false
        let sessions = try MiMoCookieImporter.importSessions(
            browserDetection: detection,
            loadRecords: { _, _, _ in [] },
            loadStores: { browser in
                guard browser == .firefox else { return [] }
                queriedFirefoxStores = true
                return [store]
            })

        #expect(queriedFirefoxStores)
        #expect(sessions.map(\.cookieHeader) == [
            "api-platform_serviceToken=svc-token; userId=1863175063",
        ])
    }

    @Test
    func `complete firefox session state replaces persisted cookies`() throws {
        let (temp, profile, backups) = try self.makeFirefoxSessionRestoreProfile(prefix: "mimo-firefox-merge")
        defer { try? FileManager.default.removeItem(at: temp) }

        let json = """
        {
          "cookies": [
            {
              "host": ".platform.xiaomimimo.com",
              "path": "/",
              "name": "api-platform_serviceToken",
              "value": "svc-token"
            },
            {"host": ".xiaomimimo.com", "path": "/", "name": "userId", "value": "1863175063"}
          ]
        }
        """
        try self.mozillaLZ4LiteralFile(json).write(to: backups.appendingPathComponent("recovery.jsonlz4"))

        let store = self.makeFirefoxCookieStore(profileDirectory: profile)
        let persisted = BrowserCookieStoreRecords(store: store, records: [
            BrowserCookieRecord(
                domain: "platform.xiaomimimo.com",
                name: "cookie-preferences",
                path: "/",
                value: "xxx",
                expires: Date(timeIntervalSince1970: 1_812_064_978),
                isSecure: false,
                isHTTPOnly: false),
            BrowserCookieRecord(
                domain: "platform.xiaomimimo.com",
                name: "api-platform_serviceToken",
                path: "/",
                value: "stale-token",
                expires: Date(timeIntervalSince1970: 1_912_064_978),
                isSecure: false,
                isHTTPOnly: false),
            BrowserCookieRecord(
                domain: "xiaomimimo.com",
                name: "userId",
                path: "/",
                value: "stale-user",
                expires: Date(timeIntervalSince1970: 1_912_064_978),
                isSecure: false,
                isHTTPOnly: false),
        ])

        let resolved = MiMoCookieImporter.recordsIncludingFirefoxSessionCookies(
            from: [persisted],
            browser: .firefox,
            stores: [store])
        let sessions = MiMoCookieImporter.sessionInfos(from: resolved)

        #expect(Set(resolved.first?.records.map(\.value) ?? []) == Set(["svc-token", "1863175063"]))
        #expect(sessions.map(\.cookieHeader) == ["api-platform_serviceToken=svc-token; userId=1863175063"])
    }

    @Test
    func `firefox session restore input is size bounded`() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimo-firefox-oversized-\(UUID().uuidString).jsonlz4")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x41, count: 5).write(to: file)

        do {
            _ = try MiMoFirefoxSessionCookieImporter.readData(from: file, maxBytes: 4)
            Issue.record("Expected oversized Firefox session restore input to fail")
        } catch let error as MiMoFirefoxSessionCookieImporter.ImportError {
            guard case .resourceLimit(.inputBytes) = error else {
                Issue.record("Unexpected Firefox session restore error: \(error)")
                return
            }
        }
    }

    @Test
    func `firefox session restore decompression is size bounded`() throws {
        var data = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])
        data.append(contentsOf: [0x1F, 0x41, 0x01, 0x00, 0x14])

        do {
            _ = try MiMoFirefoxSessionCookieImporter.decodeSessionRestoreData(data, maxOutputBytes: 32)
            Issue.record("Expected oversized Firefox session restore output to fail")
        } catch let error as MiMoFirefoxSessionCookieImporter.ImportError {
            guard case .resourceLimit(.outputBytes) = error else {
                Issue.record("Unexpected Firefox session restore error: \(error)")
                return
            }
        }
    }

    @Test
    func `firefox session restore accepts decoded size prefix`() throws {
        let json = #"{"cookies":[]}"#
        var data = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])
        var decodedSize = UInt32(json.utf8.count).littleEndian
        withUnsafeBytes(of: &decodedSize) { data.append(contentsOf: $0) }
        data.append(self.lz4LiteralBlock(Data(json.utf8)))

        let decoded = try MiMoFirefoxSessionCookieImporter.decodeSessionRestoreData(data)

        #expect(decoded == Data(json.utf8))
    }

    private func makeFirefoxSessionRestoreProfile(prefix: String) throws -> (
        temp: URL,
        profile: URL,
        backups: URL)
    {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let profile = temp
            .appendingPathComponent("Library/Application Support/Firefox/Profiles/n757crxy.default-release-1")
        let backups = profile.appendingPathComponent("sessionstore-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        return (temp: temp, profile: profile, backups: backups)
    }

    private func makeFirefoxCookieStore(
        profileDirectory: URL,
        profileID: String? = nil) -> BrowserCookieStore
    {
        BrowserCookieStore(
            browser: .firefox,
            profile: BrowserProfile(id: profileID ?? profileDirectory.path, name: profileDirectory.lastPathComponent),
            kind: .primary,
            label: "Firefox \(profileDirectory.lastPathComponent)",
            databaseURL: profileDirectory.appendingPathComponent("cookies.sqlite"))
    }
    #endif

    private func mozillaLZ4LiteralFile(_ json: String) -> Data {
        var data = Data([0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00])
        var decodedSize = UInt32(json.utf8.count).littleEndian
        withUnsafeBytes(of: &decodedSize) { data.append(contentsOf: $0) }
        data.append(self.lz4LiteralBlock(Data(json.utf8)))
        return data
    }

    private func lz4LiteralBlock(_ payload: Data) -> Data {
        var output = Data()
        let literalCount = payload.count
        if literalCount < 15 {
            output.append(UInt8(literalCount << 4))
        } else {
            output.append(0xF0)
            var remaining = literalCount - 15
            while remaining >= 255 {
                output.append(255)
                remaining -= 255
            }
            output.append(UInt8(remaining))
        }
        output.append(payload)
        return output
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private static func makeMenuCardModel(
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata,
        now: Date) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model.make(.init(
            provider: .mimo,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }

    private func makeBalanceSnapshot(provider: UsageProvider) -> UsageSnapshot {
        let updatedAt = Date(timeIntervalSince1970: 1_742_771_200)
        switch provider {
        case .openrouter:
            return OpenRouterUsageSnapshot(
                totalCredits: 50,
                totalUsage: 24.49,
                balance: 25.51,
                usedPercent: 49,
                keyDataFetched: false,
                keyLimit: nil,
                keyUsage: nil,
                rateLimit: nil,
                updatedAt: updatedAt).toUsageSnapshot()
        case .mimo:
            return MiMoUsageSnapshot(
                balance: 25.51,
                currency: "USD",
                updatedAt: updatedAt).toUsageSnapshot()
        default:
            Issue.record("Unexpected provider \(provider.rawValue)")
            return UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: updatedAt)
        }
    }

    private func makeContext(
        sourceMode: ProviderSourceMode = .auto,
        settings: ProviderSettingsSnapshot? = nil,
        environment: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: browserDetection)
    }

    private func makeCookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expiresAt: Date) throws -> HTTPCookie
    {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .expires: expiresAt,
            .secure: "TRUE",
        ]
        return try #require(HTTPCookie(properties: properties))
    }
}

final class MiMoStubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mimo.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
