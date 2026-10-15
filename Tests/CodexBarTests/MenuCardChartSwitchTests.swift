import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MenuCardChartSwitchTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `switch requires both throughput and a dashboard chart`() {
        #expect(Self.model().showsChartSwitch)
        let liveOnly = Self.model(history: false)
        #expect(!liveOnly.showsChartSwitch)
        #expect(liveOnly.throughput != nil)
        #expect(liveOnly.inlineUsageDashboard == nil)
        let spendOnly = Self.model(throughput: false)
        #expect(!spendOnly.showsChartSwitch)
        #expect(spendOnly.throughput == nil)
        #expect(spendOnly.inlineUsageDashboard != nil)
        #expect(!Self.model(throughput: false, history: false).showsChartSwitch)
    }

    @Test
    func `local preferences default to Live and persist independently per provider instance`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        let first = try #require(ProviderInstanceID(rawValue: "synthetic-first"))
        let second = try #require(ProviderInstanceID(rawValue: "synthetic-second"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let originalConfig = try encoder.encode(settings.config)
        #expect(settings.menuChartMode(for: first) == .live)
        settings.setMenuChartMode(.spend, for: first)
        #expect(settings.menuChartMode(for: first) == .spend)
        #expect(settings.menuChartMode(for: second) == .live)
        let reloaded = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(reloaded.menuChartMode(for: first) == .spend)
        settings.setMenuChartMode(.live, for: first)
        let spendOnly = Self.model(throughput: false)
        #expect(!spendOnly.showsChartSwitch)
        #expect(spendOnly.throughput == nil)
        #expect(spendOnly.inlineUsageDashboard != nil)
        #expect(settings.menuChartMode(for: first) == .live)
        #expect(try encoder.encode(settings.config) == originalConfig)
        defaults.set([first.rawValue: "unknown"], forKey: "providerMenuChartModes")
        #expect(settings.menuChartMode(for: first) == .live)
    }

    @Test
    func `chart summaries preserve both defaults and injected hover details`() throws {
        let model = Self.model()
        let live = try #require(model.throughput)
        let spend = try #require(model.inlineUsageDashboard)
        #expect(live.summary(selectedPointID: nil) == live.summaryLine)
        #expect(live.summaryLine.hasPrefix("Latest "))
        #expect(live.summaryLine.contains(" · Peak "))
        #expect(live.summary(selectedPointID: live.points[10].id) == live.points[10].hoverSummary)
        #expect(live.summary(selectedPointID: live.points.last?.id).contains("reporting") == true)
        #expect(live.summary(selectedPointID: "missing") == live.summaryLine)
        #expect(spend.chartSummary(selectedPointID: nil) == UsageFormatter.compactCurrencyString(
            UsageChartScale(values: spend.points.compactMap(\.value)).maximum, currencyCode: "USD"))
        #expect(spend.chartSummary(selectedPointID: spend.points[10].id) == spend.points[10].hoverDetail?.summary)
        #expect(spend.chartSummary(selectedPointID: "missing") == spend.chartSummary(selectedPointID: nil))
        #expect(spend.chartTitle?.hasPrefix("Daily spend · ") == true)
    }

    @Test
    func `both chart modes retain identical fitting height and union fingerprint`() {
        for limited in [false, true] {
            let model = Self.model(limited: limited)
            let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
            settings.setMenuChartMode(.live, for: model.provider.instanceID)
            let liveFingerprint = model.heightFingerprint(section: "usage")
            settings.setMenuChartMode(.spend, for: model.provider.instanceID)
            #expect(model.heightFingerprint(section: "usage") == liveFingerprint)
            for highlighted in [false, true] {
                let live = Self.host(model: model, mode: .live, highlighted: highlighted)
                let spend = Self.host(model: model, mode: .spend, highlighted: highlighted)
                #expect(live.fittingSize.height > 100)
                #expect(abs(live.fittingSize.height - spend.fittingSize.height) < 0.01)
                for mode in ProviderMenuChartMode.allCases {
                    let selected = mode == .live ? model.throughput?.points[10].id
                        : model.inlineUsageDashboard?.points[10].id
                    let hovered = Self.host(model: model, mode: mode, highlighted: highlighted, selected: selected)
                    #expect(abs(hovered.fittingSize.height - live.fittingSize.height) < 0.01)
                }
            }
        }
    }

    @Test
    func `hosted chart picker reserves its interactive region and changes selection synchronously`() {
        var mode = ProviderMenuChartMode.live
        let binding = Binding(get: { mode }, set: { mode = $0 })
        var rowClicked = false
        let row = MenuRowContainerView(
            payload: MenuCardRowPayload(
                content: AnyView(ProviderMenuChartPicker(selection: binding)
                    .frame(width: 320, height: 44, alignment: .trailing)),
                showsSubmenuIndicator: false,
                submenuIndicatorAlignment: .trailing,
                submenuIndicatorTopPadding: 0,
                allowsMenuHighlight: true,
                containsInteractiveControls: true,
                usesGPUSelection: false,
                onClick: { rowClicked = true }),
            refreshMonitor: nil)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: 51)
        row.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        row.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 280, y: 25)
        #expect(row._test_hitsHostedInteractiveControl(at: point))
        #expect(!row._test_simulateRuntimeClick(at: point))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1)
            else { continue }
            if type == .leftMouseDown { row.mouseDown(with: event) } else { row.mouseUp(with: event) }
        }
        #expect(row._test_forwardedHostedControlEvents.mouseDown)
        #expect(row._test_forwardedHostedControlEvents.mouseUp)
        #expect(!rowClicked)
        binding.wrappedValue = .spend
        #expect(mode == .spend)
    }

    @Test
    func `render fixed height chart switch proofs when requested`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_OPENAI_LIMITS_PROOF"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Self.model()
        var measurements: [String] = []
        for mode in ProviderMenuChartMode.allCases {
            for highlighted in [false, true] {
                let name = "switch-\(mode.rawValue)-\(highlighted ? "highlighted" : "normal").png"
                let height = try Self.capture(
                    Self.host(model: model, mode: mode, highlighted: highlighted),
                    to: root.appendingPathComponent(name))
                measurements.append("\(name): 350 × \(height) pt")
            }
            let selected = mode == .live ? model.throughput?.points[41].id : model.inlineUsageDashboard?.points[20].id
            let name = "switch-\(mode.rawValue)-hover.png"
            let height = try Self.capture(
                Self.host(model: model, mode: mode, highlighted: false, selected: selected),
                to: root.appendingPathComponent(name))
            measurements.append("\(name): 350 × \(height) pt")
        }
        try measurements.joined(separator: "\n").write(
            to: root.appendingPathComponent("switch-heights.txt"), atomically: true, encoding: .utf8)
        print(measurements.joined(separator: "\n"))
    }

    private static func model(
        throughput: Bool = true,
        history: Bool = true,
        limited: Bool = true) -> UsageMenuCardView.Model
    {
        let minutes = (0..<60).map { index in
            ProviderThroughputSnapshot.Minute(
                start: Self.now.addingTimeInterval(Double(index - 60) * 60),
                totalTokens: index == 41 ? 151_000_000 : 30_000_000 + ((index * 17) % 50) * 1_000_000,
                requests: 50,
                isPending: index >= 57)
        }
        let live = ProviderThroughputSnapshot(
            minutes: minutes,
            frontier: minutes[56].start,
            latestTokensPerMinute: minutes[56].totalTokens,
            peakTokensPerMinute: 151_000_000,
            peakAt: minutes[41].start,
            fiveMinuteAverageTokensPerMinute: 45_000_000,
            models: [],
            windowMinutes: 60,
            fetchedAt: Self.now,
            projectID: nil)
        let daily = OpenAIAPIUsageSnapshot(
            daily: (0..<30).map { index in
                let start = Self.now.addingTimeInterval(Double(index - 29) * 86400)
                return .init(
                    day: start.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                    startTime: start,
                    endTime: start.addingTimeInterval(86400),
                    costUSD: Double(5 + (index * 7) % 20),
                    requests: 1200,
                    inputTokens: 700_000_000,
                    cachedInputTokens: 650_000_000,
                    outputTokens: 30_000_000,
                    totalTokens: 730_000_000,
                    lineItems: [],
                    models: [.init(
                        name: "synthetic-model",
                        requests: 1200,
                        inputTokens: 700_000_000,
                        cachedInputTokens: 650_000_000,
                        outputTokens: 30_000_000,
                        totalTokens: 730_000_000)])
            }, updatedAt: Self.now)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            throughput: throughput ? live : nil,
            openAIAPIUsage: history ? daily : nil,
            updatedAt: Self.now)
        return UsageMenuCardView.Model.make(.init(
            provider: .openai,
            throughputPresentation: .init(
                limitLine: limited ? "Peak org limit: 38% · 15M / 40M · synthetic-model" : nil,
                limitPercent: limited ? 38 : nil,
                action: .openOpenAILiveUsage),
            metadata: ProviderDefaults.metadata[.openai]!,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: .init(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            preferredCurrencyCode: "USD",
            now: Self.now))
    }

    private static func host(
        model: UsageMenuCardView.Model,
        mode: ProviderMenuChartMode,
        highlighted: Bool,
        selected: String? = nil) -> NSHostingView<AnyView>
    {
        let hosting = NSHostingView(rootView: AnyView(UsageMenuCardView(model: model, width: 350)
                .environment(\.providerMenuChartSelection, .constant(mode))
                .environment(\.menuUsageBarSelection, .constant(selected))
                .environment(\.menuItemHighlighted, highlighted)
                .environment(\.colorScheme, .dark)
                .background(highlighted ? MenuHighlightStyle.selectionBackground(true)
                    : Color(nsColor: .windowBackgroundColor))))
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 350, height: 400)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private static func capture(_ hosting: NSHostingView<AnyView>, to url: URL) throws -> CGFloat {
        let height = ceil(hosting.fittingSize.height)
        hosting.frame.size.height = height
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return height
    }
}
