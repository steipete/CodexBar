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
            MiMoCookieImporter.importSessionsOverrideForTesting = nil
            CookieHeaderCache.clear(provider: .mimo)
        }

        CookieHeaderCache.clear(provider: .mimo)
        CookieHeaderCache.store(provider: .mimo, cookieHeader: "invalid", sourceLabel: "invalid")

        MiMoCookieImporter.importSessionsOverrideForTesting = { _, _ in
            [
                .init(
                    cookieHeader: "api-platform_serviceToken=expired-token; userId=111",
                    sourceLabel: "Expired Chrome"),
                .init(
                    cookieHeader: "api-platform_serviceToken=valid-token; userId=222",
                    sourceLabel: "Active Chrome"),
            ]
        }

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
            MiMoCookieImporter.importSessionsOverrideForTesting = nil
            CookieHeaderCache.clear(provider: .mimo)
        }

        CookieHeaderCache.clear(provider: .mimo)
        CookieHeaderCache.store(
            provider: .mimo,
            cookieHeader: "api-platform_serviceToken=stale-chrome-token; userId=111",
            sourceLabel: "Chrome")

        MiMoCookieImporter.importSessionsOverrideForTesting = { _, _ in
            [
                .init(
                    cookieHeader: "api-platform_serviceToken=stale-chrome-token; userId=111",
                    sourceLabel: "Chrome"),
                .init(
                    cookieHeader: "api-platform_serviceToken=valid-safari-token; userId=222",
                    sourceLabel: "Safari"),
            ]
        }

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
    #endif

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
