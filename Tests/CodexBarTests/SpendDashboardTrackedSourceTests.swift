import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct SpendDashboardTrackedSourceTests {
    @Test
    @MainActor
    func `tracked access keeps enabled providers visible across connection states`() throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardTrackedSourceTests-enabled")
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: [.cursor, .gemini, .grok, .openrouter].contains(provider))
        }
        settings.addTokenAccount(provider: .cursor, label: "Work", token: "fixture")

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 10,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .grok)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .gemini)
        store._setErrorForTesting("Not logged in", provider: .gemini)

        let sources = SpendDashboardSource.trackedSources(settings: settings, store: store)
        let rows = Dictionary(uniqueKeysWithValues: sources.map { ($0.provider, $0) })

        #expect(Set(rows.keys).isSuperset(of: [.cursor, .gemini, .grok, .openrouter]))
        #expect(rows[.grok]?.state == .connected)
        #expect(rows[.gemini]?.state == .needsAttention)
        #expect(rows[.openrouter]?.state == .awaitingUsage)
        #expect(rows[.openrouter]?.supportsCostHistory == false)
        #expect(Set(rows.values.filter(\.contributesCostHistory).map(\.provider)) == [.cursor])
    }

    @Test
    @MainActor
    func `automatic provider fetch with dormant saved account emits one ambient current source`() throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardTrackedSourceTests-ambient-account")
        let metadata = try #require(ProviderRegistry.shared.metadata[.cursor])
        try settings.setProviderEnabled(provider: .cursor, metadata: metadata, enabled: true)
        settings.addTokenAccount(provider: .cursor, label: "Dormant manual account", token: "fixture")
        let account = try #require(settings.selectedTokenAccount(for: .cursor))
        settings.cursorCookieSource = .auto
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) == nil)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let sources = SpendDashboardSource.trackedSources(settings: settings, store: store)
            .filter { $0.provider == .cursor }
        let accountID = "cursor:account:\(account.id.uuidString.lowercased())"

        #expect(Set(sources.map(\.id)) == [accountID, "cursor:current"])
        #expect(sources.first { $0.id == accountID }?.contributesCostHistory == false)
        #expect(sources.first { $0.id == "cursor:current" }?.contributesCostHistory == true)

        let date = Date(timeIntervalSince1970: 1_785_974_400)
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "cursor",
                        rank: 1,
                        provider: .cursor,
                        displayName: "Cursor",
                        totalTokens: 900,
                        totalCost: 9,
                        coveredDayCount: 30),
                ],
                models: [],
                dailyPoints: [],
                totalTokens: 900,
                totalCost: 9,
                coveredDayCount: 30,
                chartDomain: date...date,
                modelHistoryCompleteness: .complete),
        ])
        let payload = try #require(SpendDashboardPane.makeSharePayload(
            model: model,
            subscriptionNames: [:],
            trackedSources: sources))

        #expect(payload.providers.first?.provider == .cursor)
        #expect(payload.providers.first?.estimatedCost == 9)
        #expect(payload.providers.first?.totalTokens == 900)
        #expect(payload.currencies.first?.estimatedCost == 9)
        #expect(payload.currencies.first?.isPartial == false)
        #expect(payload.totalTokens == 900)
        #expect(payload.totalTokensIsPartial == false)
    }

    @Test
    @MainActor
    func `active saved account does not duplicate provider with an ambient current source`() throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardTrackedSourceTests-active-account")
        let metadata = try #require(ProviderRegistry.shared.metadata[.cursor])
        try settings.setProviderEnabled(provider: .cursor, metadata: metadata, enabled: true)
        settings.addTokenAccount(provider: .cursor, label: "Active manual account", token: "fixture")
        let account = try #require(settings.effectiveSelectedTokenAccount(for: .cursor))

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let sources = SpendDashboardSource.trackedSources(settings: settings, store: store)
            .filter { $0.provider == .cursor }

        #expect(sources.count == 1)
        #expect(sources.first?.id == "cursor:account:\(account.id.uuidString.lowercased())")
        #expect(sources.first?.contributesCostHistory == true)
        #expect(!sources.contains { $0.id == "cursor:current" })
    }

    @Test
    @MainActor
    func `quota usage does not claim cost history is connected`() throws {
        let settings = testSettingsStore(suiteName: "SpendDashboardTrackedSourceTests-quota-only")
        let metadata = try #require(ProviderRegistry.shared.metadata[.openrouter])
        try settings.setProviderEnabled(provider: .openrouter, metadata: metadata, enabled: true)
        settings[providerConfig: .openrouter, field: .apiKey] = "fixture-key"

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .openrouter)

        let source = try #require(SpendDashboardSource.trackedSources(settings: settings, store: store).first {
            $0.provider == .openrouter
        })

        #expect(spendDashboardTrackedSourceStatusText(source) == "Usage connected · not in cost total")

        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyCoverageIsEstablished: false,
            daily: [],
            updatedAt: Date()), provider: .openrouter)
        let sourceWithUnestablishedCost = try #require(SpendDashboardSource.trackedSources(
            settings: settings,
            store: store).first { $0.provider == .openrouter })
        #expect(spendDashboardTrackedSourceStatusText(sourceWithUnestablishedCost) ==
            "Usage connected · not in cost total")

        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            daily: [],
            updatedAt: Date()), provider: .openrouter)
        let sourceWithCost = try #require(SpendDashboardSource.trackedSources(
            settings: settings,
            store: store).first { $0.provider == .openrouter })
        #expect(spendDashboardTrackedSourceStatusText(sourceWithCost) == "Usage connected · not in cost total")
    }

    @Test
    func `inactive Codex account with loaded spend presents cost history as connected`() throws {
        let source = SpendDashboardTrackedSource(
            id: "codex:work",
            provider: .codex,
            providerName: "Codex",
            accountName: "Work",
            state: .configured,
            supportsCostHistory: true,
            contributesCostHistory: true)
        let date = Date(timeIntervalSince1970: 1_785_974_400)
        let model = SpendDashboardModel(requestedDays: 30, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "codex:work",
                        rank: 1,
                        provider: .codex,
                        displayName: "Codex · Work",
                        totalTokens: 100,
                        totalCost: 2,
                        coveredDayCount: 30),
                ],
                models: [],
                dailyPoints: [],
                totalTokens: 100,
                totalCost: 2,
                coveredDayCount: 30,
                chartDomain: date...date,
                modelHistoryCompleteness: .complete),
        ])

        let presented = try #require(spendDashboardTrackedSourcesForPresentation(
            [source],
            model: model).first)
        #expect(presented.costHistoryAvailable)
        #expect(spendDashboardTrackedSourceStatusText(presented) == "Cost history connected")
    }

    @Test
    @MainActor
    func `tracked access includes every saved provider credential without inventing cost coverage`() {
        let settings = testSettingsStore(suiteName: "SpendDashboardTrackedSourceTests-credentials")
        let supportedProviders = UsageProvider.allCases.filter {
            TokenAccountSupportCatalog.support(for: $0) != nil
        }
        for provider in supportedProviders {
            settings.addTokenAccount(provider: provider, label: "\(provider.rawValue) account", token: "fixture")
        }
        settings.addTokenAccount(provider: .openrouter, label: "second account", token: "fixture-2")

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let sources = SpendDashboardSource.trackedSources(settings: settings, store: store)
        let credentialSources = sources.filter { $0.id.contains(":account:") }

        #expect(Set(credentialSources.map(\.provider)) == Set(supportedProviders))
        #expect(credentialSources.count == supportedProviders.count + 1)
        #expect(Set(credentialSources.map(\.id)).count == credentialSources.count)

        let openRouterSources = credentialSources.filter { $0.provider == .openrouter }
        #expect(openRouterSources.count == 2)
        #expect(openRouterSources.allSatisfy { $0.state == .configured })
        #expect(openRouterSources.allSatisfy { !$0.supportsCostHistory })
        #expect(openRouterSources.allSatisfy { !$0.contributesCostHistory })
    }

    @Test
    func `tracked access copy distinguishes missing cost history from zero spend`() {
        let source = SpendDashboardTrackedSource(
            id: "openrouter:account:test",
            provider: .openrouter,
            providerName: "OpenRouter",
            accountName: "Work",
            state: .connected,
            supportsCostHistory: false,
            contributesCostHistory: false)

        #expect(spendDashboardTrackedSourceStatusText(source) == "Usage connected · not in cost total")

        let attention = SpendDashboardTrackedSource(
            id: "gemini:current",
            provider: .gemini,
            providerName: "Gemini",
            accountName: nil,
            state: .needsAttention,
            supportsCostHistory: false,
            contributesCostHistory: false)
        #expect(spendDashboardTrackedSourceStatusText(attention) == "Unavailable")

        let setup = SpendDashboardTrackedSource(
            id: "openrouter:current",
            provider: .openrouter,
            providerName: "OpenRouter",
            accountName: nil,
            state: .awaitingUsage,
            supportsCostHistory: false,
            contributesCostHistory: false)
        #expect(spendDashboardTrackedSourceStatusText(setup) == "No usage yet")
    }

    @Test
    @MainActor
    func `tracked access renders without clipping at wide and narrow settings widths`() throws {
        let proofDirectory = ProcessInfo.processInfo.environment["CODEXBAR_SPEND_DASHBOARD_PROOF_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let proofDirectory {
            try FileManager.default.createDirectory(
                at: proofDirectory,
                withIntermediateDirectories: true)
        }

        for (size, filename) in [
            (CGSize(width: 760, height: 440), "spend-dashboard-tracked-access-wide.png"),
            (CGSize(width: 430, height: 720), "spend-dashboard-tracked-access-narrow.png"),
        ] {
            let view = VStack(alignment: .leading, spacing: 18) {
                SpendDashboardHeader(
                    selectedDays: 365,
                    isRefreshing: false,
                    isCostTrackingEnabled: true,
                    selectDays: { _ in },
                    refresh: {})
                SpendTrackedAccessPanel(
                    sources: Self.proofSources,
                    description: "Every configured subscription or key stays visible. "
                        + "Only compatible sources enter cost totals.")
            }
            .padding(24)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))

            let data = try #require(Self.pngData(for: view, size: size))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == Int(size.width))
            #expect(bitmap.pixelsHigh == Int(size.height))
            if let proofDirectory {
                try data.write(to: proofDirectory.appendingPathComponent(filename), options: .atomic)
            }
        }
    }

    private static let proofSources = [
        SpendDashboardTrackedSource(
            id: "codex:account:personal",
            provider: .codex,
            providerName: "Codex",
            accountName: "Personal",
            state: .connected,
            supportsCostHistory: true,
            contributesCostHistory: true,
            costHistoryAvailable: true),
        SpendDashboardTrackedSource(
            id: "claude:account:team",
            provider: .claude,
            providerName: "Claude",
            accountName: "Team",
            state: .connected,
            supportsCostHistory: true,
            contributesCostHistory: true,
            costHistoryAvailable: true),
        SpendDashboardTrackedSource(
            id: "openrouter:account:research",
            provider: .openrouter,
            providerName: "OpenRouter",
            accountName: "Research",
            state: .awaitingUsage,
            supportsCostHistory: false,
            contributesCostHistory: false),
        SpendDashboardTrackedSource(
            id: "cursor:account:work",
            provider: .cursor,
            providerName: "Cursor",
            accountName: "Work",
            state: .configured,
            supportsCostHistory: true,
            contributesCostHistory: false),
        SpendDashboardTrackedSource(
            id: "gemini:account:studio",
            provider: .gemini,
            providerName: "Gemini",
            accountName: "Studio",
            state: .needsAttention,
            supportsCostHistory: false,
            contributesCostHistory: false),
        SpendDashboardTrackedSource(
            id: "mistral:account:api",
            provider: .mistral,
            providerName: "Mistral",
            accountName: "API",
            state: .configured,
            supportsCostHistory: true,
            contributesCostHistory: false),
    ]

    @MainActor
    private static func pngData(for rootView: some View, size: CGSize) -> Data? {
        let view = NSHostingView(rootView: rootView)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        view.displayIgnoringOpacity(view.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }
}
