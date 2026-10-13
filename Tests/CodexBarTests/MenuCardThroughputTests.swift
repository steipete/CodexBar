import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MenuCardThroughputTests {
    @Test
    func `live and stacked cards use their own credential limits and unknown owners omit utilization`() async throws {
        let snapshot = try await OpenAIThroughputTests.mappedLive(
            OpenAIThroughputTests.liveSource(OpenAIThroughputTests.livePayload), engine: .quickJS)
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.addTokenAccount(provider: .openai, label: "A", token: "synthetic-a")
        let a = try #require(settings.selectedTokenAccount(for: .openai))
        settings.addTokenAccount(provider: .openai, label: "B", token: "synthetic-b")
        let b = try #require(settings.selectedTokenAccount(for: .openai))
        settings.updateProviderConfig(provider: .openai, affectsBackgroundWork: false) {
            $0.setModelRateLimits(
                [.init(model: OpenAIThroughputTests.model, tokensPerMinute: 10_000_000)],
                for: .provider)
            $0.setModelRateLimits(
                [.init(model: OpenAIThroughputTests.model, tokensPerMinute: 40_000_000)],
                for: .tokenAccount(a.id))
            $0.setModelRateLimits(
                [.init(model: OpenAIThroughputTests.model, tokensPerMinute: 80_000_000)],
                for: .tokenAccount(b.id))
        }
        settings.setActiveTokenAccountIndex(0, for: .openai)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store.snapshots[.openai] = snapshot
        let live = store.menuCardModel(for: .openai)
        #expect(abs((live.throughput?.presentation?.limitPercent ?? 0) - 242.5) < 0.001)
        #expect(live.throughput?.presentation?.action == .openOpenAILiveUsage)
        let selected = store.menuCardModel(
            for: .openai, context: .account(.init(snapshot: snapshot, tokenAccountID: a.id)))
        #expect(abs((selected.throughput?.presentation?.limitPercent ?? 0) - 242.5) < 0.001)
        #expect(selected.throughput?.presentation?.action == .openOpenAILiveUsage)
        let stacked = store.menuCardModel(
            for: .openai, context: .account(.init(snapshot: snapshot, tokenAccountID: b.id)))
        #expect(abs((stacked.throughput?.presentation?.limitPercent ?? 0) - 121.25) < 0.001)
        #expect(stacked.throughput?.presentation?.action == nil)
        #expect(stacked.throughput?.presentation?.limitLine != nil)
        let unknown = store.menuCardModel(for: .openai, context: .account(.init(snapshot: snapshot)))
        #expect(unknown.throughput?.presentation?.limitLine == nil)
        #expect(unknown.throughput?.presentation?.limitPercent == nil)
        #expect(unknown.throughput?.presentation?.action == nil)
        #expect(unknown.throughput?.snapshot == snapshot.throughput)
        let throughput = try #require(snapshot.throughput)
        let nilScope = OpenAIAPIProviderImplementation().throughputPresentation(
            snapshot: throughput, settings: settings, limitScope: nil)
        #expect(nilScope?.limitLine == nil)
        #expect(nilScope?.action == .openOpenAILiveUsage)
        settings.setActiveTokenAccountIndex(1, for: .openai)
        let switched = store.menuCardModel(for: .openai)
        #expect(abs((switched.throughput?.presentation?.limitPercent ?? 0) - 121.25) < 0.001)
        #expect(switched.throughput?.presentation?.action == .openOpenAILiveUsage)
        let switchedA = store.menuCardModel(
            for: .openai, context: .account(.init(snapshot: snapshot, tokenAccountID: a.id)))
        #expect(switchedA.throughput?.presentation?.action == nil)
        #expect(abs((switchedA.throughput?.presentation?.limitPercent ?? 0) - 242.5) < 0.001)
        let switchedB = store.menuCardModel(
            for: .openai, context: .account(.init(snapshot: snapshot, tokenAccountID: b.id)))
        #expect(switchedB.throughput?.presentation?.action == .openOpenAILiveUsage)
        #expect(abs((switchedB.throughput?.presentation?.limitPercent ?? 0) - 121.25) < 0.001)
        #expect(store.menuCardModel(for: .openai, context: .account(.init(snapshot: snapshot)))
            .throughput?.presentation?.action == nil)
    }

    @Test
    func `throughput section and manual org limit are optional and height sensitive`() async throws {
        let snapshot = try await OpenAIThroughputTests.mappedLive(
            OpenAIThroughputTests.liveSource(OpenAIThroughputTests.livePayload),
            engine: .quickJS)
        let throughput = try #require(snapshot.throughput)
        let absent = self.model(snapshot: nil)
        let plain = self.model(snapshot: snapshot)
        #expect(absent.throughput == nil)
        #expect(plain.throughput != nil)
        #expect(plain.throughput?.presentation?.limitLine == nil)
        let manual = [ProviderModelRateLimit(
            model: OpenAIThroughputTests.model,
            tokensPerMinute: 40_000_000)]
        let limited = self.model(
            snapshot: snapshot,
            manual: manual)
        // Cached input counts toward TPM: a 97M peak of a 40M limit.
        #expect(abs((limited.throughput?.presentation?.limitPercent ?? 0) - 242.5) < 0.001)
        #expect(limited.throughput?.presentation?.limitLine?.contains("97M") == true)
        #expect(limited.throughput?.presentation?.action == .openOpenAILiveUsage)
        #expect(plain.heightFingerprint(section: "usage") != limited.heightFingerprint(section: "usage"))
        #expect(!plain.hasCompatibleTrackedLayout(with: limited))
        #expect(absent.heightFingerprint(section: "usage") != plain.heightFingerprint(section: "usage"))
        var changed = plain
        changed.throughput?.presentation?.limitLine = "A longer synthetic manual limit line"
        #expect(changed.heightFingerprint(section: "usage") != plain.heightFingerprint(section: "usage"))
        let unmatched = self.model(
            snapshot: snapshot,
            manual: [.init(
                model: "another-model",
                tokensPerMinute: 10)])
        #expect(unmatched.throughput?.presentation?.limitLine == nil)
        #expect(throughput.minutes.suffix(3).filter { !$0.isPending }.isEmpty)
    }

    @Test
    func `limit line selects highest limited utilization and uses its standard peak`() {
        let models: [ProviderThroughputSnapshot.Model] = [
            .init(
                name: "model-unlimited",
                latestTPM: 2000,
                peakTPM: 2000,
                totalTokens: 2000,
                peakLimitCountedTokens: 2000),
            .init(
                name: "model-batch-heavy",
                latestTPM: 1000,
                peakTPM: 1000,
                totalTokens: 1000,
                peakLimitCountedTokens: 10),
            .init(
                name: "model-fixture",
                latestTPM: 200,
                peakTPM: 300,
                totalTokens: 300,
                peakLimitCountedTokens: 180),
            .init(
                name: "model-tied",
                latestTPM: 100,
                peakTPM: 100,
                totalTokens: 100,
                peakLimitCountedTokens: 90),
        ]
        let snapshot = ProviderThroughputSnapshot(
            minutes: [],
            frontier: nil,
            latestTokensPerMinute: nil,
            peakTokensPerMinute: 2000,
            peakAt: nil,
            fiveMinuteAverageTokensPerMinute: 0,
            models: models,
            windowMinutes: 60,
            fetchedAt: OpenAIThroughputTests.now,
            projectID: nil)
        let result = OpenAIAPIProviderImplementation.throughputPresentation(snapshot: snapshot, manual: [
            .init(model: "model-batch-heavy", tokensPerMinute: 100),
            .init(model: "model-fixture", tokensPerMinute: 200),
            .init(model: "model-tied", tokensPerMinute: 100),
        ])
        #expect(result.limitPercent == 90)
        #expect(result.limitLine == L("%@ · peak %@ · %@ of org limit", "model-fixture", "180", "90%"))
    }

    @Test
    func `sixth ranked model with a small manual limit drives the line`() throws {
        let snapshot = try OpenAILiveUsageBuilder.build(
            buckets: [.init(start: OpenAIThroughputTests.now.addingTimeInterval(-85), models: (1...6).map {
                .init(
                    name: "model-\($0)",
                    inputTokens: $0 * 100,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    requests: 1)
            })],
            windowMinutes: 60,
            fetchedAt: OpenAIThroughputTests.now,
            projectID: nil).throughput
        #expect(snapshot.models.last?.name == "model-1")
        let result = OpenAIAPIProviderImplementation.throughputPresentation(snapshot: snapshot, manual: [
            .init(model: "model-6", tokensPerMinute: 1000),
            .init(model: "model-1", tokensPerMinute: 50),
        ])
        #expect(result.limitPercent == 200)
        #expect(result.limitLine == L("%@ · peak %@ · %@ of org limit", "model-1", "100", "200%"))
    }

    @Test
    func `pooled limit line sums simultaneous traffic and keeps earlier groups on ties`() {
        let snapshot = Self.pooledSnapshot(firstSeries: [60, 40, 1000], secondSeries: [60, 70, 1000])
        let result = OpenAIAPIProviderImplementation.throughputPresentation(snapshot: snapshot, manual: [
            .init(model: "gpt-5", tokensPerMinute: 100),
            .init(model: "gpt-4o", tokensPerMinute: 100),
        ])
        // The largest simultaneous sum is 60 + 60, not the separate peaks 60 + 70.
        #expect(result.limitPercent == 120)
        #expect(result.limitLine == L("%@ · peak %@ · %@ of org limit", "gpt-5", "120", "120%"))
        #expect(result.action == .openOpenAILiveUsage)
        let exact = OpenAIAPIProviderImplementation.throughputPresentation(snapshot: snapshot, manual: [
            .init(model: "gpt-5", tokensPerMinute: 100),
            .init(model: "gpt-5-2025-08-07", tokensPerMinute: 50),
        ])
        #expect(exact.limitPercent == 140)
        #expect(exact.limitLine == L("%@ · peak %@ · %@ of org limit", "gpt-5-2025-08-07", "70", "140%"))
    }

    @Test(arguments: [nil, [60, 70]] as [[Int]?])
    func `missing or misaligned pooled series fall back to per model peaks`(secondSeries: [Int]?) {
        let snapshot = Self.pooledSnapshot(firstSeries: [60, 40, 1000], secondSeries: secondSeries)
        let result = OpenAIAPIProviderImplementation.throughputPresentation(snapshot: snapshot, manual: [
            .init(model: "gpt-5", tokensPerMinute: 100),
        ])
        #expect(result.limitPercent == 70)
        #expect(result.limitLine == L("%@ · peak %@ · %@ of org limit", "gpt-5", "70", "70%"))
        let old = Self.pooledSnapshot(firstSeries: nil, secondSeries: nil)
        #expect(OpenAIAPIProviderImplementation.throughputPresentation(snapshot: old, manual: [
            .init(model: "gpt-5", tokensPerMinute: 100),
        ]).limitPercent == 70)
    }

    private static func pooledSnapshot(firstSeries: [Int]?, secondSeries: [Int]?) -> ProviderThroughputSnapshot {
        ProviderThroughputSnapshot(
            minutes: [
                .init(
                    start: OpenAIThroughputTests.now.addingTimeInterval(-150),
                    totalTokens: 240,
                    requests: 12,
                    isPending: false),
                .init(
                    start: OpenAIThroughputTests.now.addingTimeInterval(-90),
                    totalTokens: 110,
                    requests: 11,
                    isPending: false),
                .init(
                    start: OpenAIThroughputTests.now.addingTimeInterval(-30),
                    totalTokens: 2000,
                    requests: 200,
                    isPending: true),
            ],
            frontier: OpenAIThroughputTests.now.addingTimeInterval(-90),
            latestTokensPerMinute: 110,
            peakTokensPerMinute: 240,
            peakAt: OpenAIThroughputTests.now.addingTimeInterval(-150),
            fiveMinuteAverageTokensPerMinute: 175,
            models: [
                .init(
                    name: "gpt-5",
                    latestTPM: 40,
                    peakTPM: 60,
                    totalTokens: 1100,
                    peakLimitCountedTokens: 60,
                    limitCountedTokensByMinute: firstSeries),
                .init(
                    name: "gpt-5-2025-08-07",
                    latestTPM: 70,
                    peakTPM: 70,
                    totalTokens: 1130,
                    peakLimitCountedTokens: 70,
                    limitCountedTokensByMinute: secondSeries),
                .init(
                    name: "gpt-4o",
                    latestTPM: 0,
                    peakTPM: 120,
                    totalTokens: 120,
                    peakLimitCountedTokens: 120,
                    limitCountedTokensByMinute: [120, 0, 0]),
            ],
            windowMinutes: 60,
            fetchedAt: OpenAIThroughputTests.now,
            projectID: nil)
    }

    @Test
    func `project scoped snapshots never report org limit utilization`() throws {
        let manual = [ProviderModelRateLimit(model: OpenAIThroughputTests.model, tokensPerMinute: 40_000_000)]
        func presentation(projectID: String?) throws -> ProviderThroughputPresentation {
            try OpenAIAPIProviderImplementation.throughputPresentation(
                snapshot: OpenAIAPIProviderDescriptor.mapLiveUsage(
                    JSONProviderPluginValue(OpenAIThroughputTests.livePayload),
                    projectID: projectID,
                    maximumEntries: 10000).throughput,
                manual: manual)
        }
        #expect(try presentation(projectID: nil).limitLine != nil)
        // The cached snapshot's scope decides, independent of the current project setting.
        let scoped = try presentation(projectID: "proj_fixture")
        #expect(scoped.limitLine == nil)
        #expect(scoped.limitPercent == nil)
        #expect(scoped.action == .openOpenAILiveUsage)
    }

    @Test
    func `Tokens per minute toggle defaults on and persists plugin setting`() throws {
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = ProviderSettingsContext(
            provider: .openai,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let toggle = try #require(OpenAIAPIProviderImplementation().settingsToggles(context: context).first)
        #expect(toggle.binding.wrappedValue)
        toggle.binding.wrappedValue = false
        #expect(settings.providerConfig(for: .openai)?.pluginSettings?["OPENAI_LIVE_MINUTES"] == "0")
        let adapter = try #require(OpenAIAPIProviderDescriptor.descriptor.credentials)
        let environment = adapter.applyConfig(
            base: [:],
            config: settings.providerConfig(for: .openai))
        #expect(environment["OPENAI_LIVE_MINUTES"] == "0")
        toggle.binding.wrappedValue = true
        #expect(settings.providerConfig(for: .openai)?.pluginSettings?["OPENAI_LIVE_MINUTES"] == "60")
    }

    @Test
    func `render synthetic throughput card and menu bar token when requested`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_OPENAI_LIMITS_PROOF"] else { return }
        var live = OpenAIThroughputTests.livePayload
        live["buckets"] = (0..<57).map { index in
            let total = index == 41 ? 151_000_000 :
                (index == 56 ? 49_000_000 : 30_000_000 + ((index * 17) % 50) * 1_000_000)
            return ["startTime": 116_460 + index * 60, "models": [[
                "name": OpenAIThroughputTests.model, "inputTokens": total - 1_000_000,
                "cachedInputTokens": total - 5_000_000, "outputTokens": 1_000_000, "requests": 50,
            ]]] as [String: Any]
        }
        let liveSnapshot = try await OpenAIThroughputTests.mappedLive(
            OpenAIThroughputTests.liveSource(live),
            engine: .quickJS)
        let history = OpenAIAPIUsageSnapshot(
            daily: (0..<2).map { index in
                let start = Date(timeIntervalSince1970: Double(index * 86400))
                return .init(
                    day: index == 0 ? "1970-01-01" : "1970-01-02",
                    startTime: start,
                    endTime: start.addingTimeInterval(86400),
                    costUSD: index == 0 ? 18.5 : 12.25,
                    requests: 1200,
                    inputTokens: 700_000_000,
                    cachedInputTokens: 650_000_000,
                    outputTokens: 30_000_000,
                    totalTokens: 730_000_000,
                    lineItems: [],
                    models: [])
            },
            updatedAt: OpenAIThroughputTests.now)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            throughput: liveSnapshot.throughput,
            openAIAPIUsage: history,
            updatedAt: OpenAIThroughputTests.now,
            identity: liveSnapshot.identity)
        let model = self.model(
            snapshot: snapshot,
            manual: [.init(
                model: OpenAIThroughputTests.model,
                tokensPerMinute: 40_000_000)])
        let root = URL(fileURLWithPath: directory)
        let phase = ProcessInfo.processInfo.environment["CODEXBAR_BARS_PROOF_PHASE"] ?? "after"
        for highlighted in [false, true] {
            try Self.render(
                UsageMenuCardView(model: model, width: 350)
                    .environment(\.colorScheme, .dark)
                    .environment(\.menuItemHighlighted, highlighted)
                    .environment(\.menuUsageBarSelection, .constant(phase == "before" ? "41" : "118920.0"))
                    .background(highlighted ? MenuHighlightStyle.selectionBackground(true) : Color.clear),
                width: 350,
                to: root.appendingPathComponent("openai-card-\(phase)-\(highlighted ? "highlighted" : "normal").png"))
        }
        let dashboard = try #require(model.inlineUsageDashboard)
        for highlighted in [false, true] {
            try Self.render(
                InlineUsageDashboardContent(model: dashboard)
                    .padding(20)
                    .environment(\.colorScheme, .dark)
                    .environment(\.menuItemHighlighted, highlighted)
                    .background(highlighted ? MenuHighlightStyle.selectionBackground(true) : Color.clear),
                width: 350,
                to: root.appendingPathComponent("daily-bars-after-\(highlighted ? "highlighted" : "normal").png"))
        }
        var data = MenuBarLayoutRendererTests().data(provider: .openai, accountLabel: nil)
        data.tokensPerMinute = snapshot.throughput?.latestTokensPerMinute
        data.tokensSparkline = snapshot.throughput.map { MenuBarTokensSparkline(minutes: $0.minutes) }
        // Each token is its own editor entry; render them alone and side by side, without a stand-in icon.
        let layouts: [(name: String, tokens: [MenuBarLayoutToken], width: CGFloat)] = [
            ("text", [.tokensPerMinute], 90),
            ("graph", [.tokensSparkline], 70),
            ("text-graph", [.tokensPerMinute, .tokensSparkline], 140),
        ]
        for dark in [false, true] {
            for layout in layouts {
                let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
                let output = MenuBarLayoutRenderer().render(
                    layout: .init(lines: [layout.tokens]),
                    data: data,
                    icon: nil,
                    options: MenuBarLayoutRendererTests().options(appearanceName: appearance.rawValue))
                let label = NSTextField(labelWithAttributedString: output.attributedTitle)
                label.textColor = dark ? .white : .black
                let hosting = NSHostingView(rootView: NativeLayoutProofView(view: label).padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                try Self.capture(
                    hosting,
                    width: layout.width,
                    appearance: appearance,
                    to: root.appendingPathComponent("menu-bar-\(layout.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test
    func `rows with a live chart forward chart presses even without the switch`() async throws {
        let live = try await OpenAIThroughputTests.mappedLive(
            OpenAIThroughputTests.liveSource(OpenAIThroughputTests.livePayload),
            engine: .quickJS)
        let withChart = self.model(snapshot: UsageSnapshot(
            primary: nil,
            secondary: nil,
            throughput: live.throughput,
            updatedAt: OpenAIThroughputTests.now))
        #expect(!withChart.showsChartSwitch)
        #expect(withChart.containsInteractiveControls)
        #expect(!self.model(snapshot: nil).containsInteractiveControls)
    }

    private func model(
        snapshot: UsageSnapshot?,
        manual: [ProviderModelRateLimit] = []) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model.make(.init(
            provider: .openai,
            throughputPresentation: snapshot?.throughput.map {
                OpenAIAPIProviderImplementation.throughputPresentation(
                    snapshot: $0,
                    manual: manual)
            },
            metadata: ProviderDefaults.metadata[.openai]!,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: .init(
                email: nil,
                plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: OpenAIThroughputTests.now))
    }

    private static func render(
        _ view: some View,
        width: CGFloat,
        to url: URL) throws
    {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        try self.capture(
            hosting,
            width: width,
            to: url)
    }

    private static func capture(
        _ hosting: NSView,
        width: CGFloat,
        appearance: NSAppearance.Name = .darkAqua,
        to url: URL) throws
    {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: 400)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let height = ceil(hosting.fittingSize.height)
        hosting.frame.size = NSSize(
            width: width,
            height: max(30, height))
        window.setContentSize(hosting.frame.size)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(
            in: hosting.bounds,
            to: bitmap)
        try #require(bitmap.representation(
            using: .png,
            properties: [:])).write(to: url)
    }
}

private struct NativeLayoutProofView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context _: Context) -> NSView { self.view }
    func updateNSView(_: NSView, context _: Context) {}
}
