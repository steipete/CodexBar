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

        #expect(Set(rows.keys) == [.cursor, .gemini, .grok, .openrouter])
        #expect(rows[.grok]?.state == .connected)
        #expect(rows[.gemini]?.state == .needsAttention)
        #expect(rows[.openrouter]?.state == .awaitingUsage)
        #expect(rows[.openrouter]?.supportsCostHistory == true)
        #expect(rows.values.filter(\.contributesCostHistory).map(\.provider) == [.cursor])
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
        #expect(openRouterSources.allSatisfy(\.supportsCostHistory))
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
            supportsCostHistory: true,
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
            supportsCostHistory: true,
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
            contributesCostHistory: true),
        SpendDashboardTrackedSource(
            id: "claude:account:team",
            provider: .claude,
            providerName: "Claude",
            accountName: "Team",
            state: .connected,
            supportsCostHistory: true,
            contributesCostHistory: true),
        SpendDashboardTrackedSource(
            id: "openrouter:account:research",
            provider: .openrouter,
            providerName: "OpenRouter",
            accountName: "Research",
            state: .awaitingUsage,
            supportsCostHistory: true,
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
