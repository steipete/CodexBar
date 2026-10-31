import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MachineSpendTests {
    @Test
    func `shared host input commits with monitoring off and explains invalid aliases`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.agentSessionsEnabled = false
        settings.agentSessionsRemoteEnabled = false
        let (window, hosting) = Self.hostEditor(settings: settings)
        defer { window.contentView = nil; window.close() }
        let field = try #require(Self.textFields(in: hosting).first { $0.isEditable })
        try #require(field.isEnabled, "Manual cost-host setup must not require automatic monitoring.")
        let guidance = try #require(RemoteCodexCostError.invalidHost.errorDescription)
        Self.submit("devbox", through: field)
        #expect(settings.agentSessionsManualHosts == "devbox")
        hosting.layoutSubtreeIfNeeded()
        #expect(!MenuLayoutScreenshotRenderTests.accessibilityText(hosting).contains(guidance))
        Self.submit("bad/path", through: field)
        try #require(settings.agentSessionsManualHosts == "bad/path", "The test must drive the real commit path.")
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        var visible = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
        while !visible.contains(guidance), Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
            hosting.layoutSubtreeIfNeeded()
            visible = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
        }
        try #require(
            visible.contains(L("agent_sessions_hosts_title")),
            "The text traversal must find the real label: \(visible)")
        #expect(visible.contains(guidance), "Rejected input must show its existing actionable host-format guidance.")
    }

    @Test
    func `machine source rows show collector recovery guidance only after failure`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.codex], settings: settings)
        settings.costUsageEnabled = true
        settings.hidePersonalInfo = false
        settings.agentSessionsManualHosts = "fixture-host"
        settings.costUsageHosts = ["fixture-host"]
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        let environment = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(cacheRoot: root.appendingPathComponent("cost")),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: root.appendingPathComponent("history")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
            startupBehavior: .testing,
            environmentBase: environment,
            pluginApprovalStore: ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("approvals")),
            widgetSnapshotURL: root.appendingPathComponent("widget"),
            cliUsageCacheURL: root.appendingPathComponent("cli"),
            widgetTimelineReloader: {})
        store._test_providerRefreshOverride = { _ in Issue.record("Unexpected provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        defer { store.stopSharedSpendDashboardPublication(); settings.configFileWatcher?.stop() }
        for unavailable in [true, false] {
            let controller = SpendDashboardController(
                userDefaults: InMemoryUserDefaults(),
                requestBuilder: Self.loadRequest,
                machineLoader: { hosts, _, start, end in
                    let recovery = "Fixture remote recovery guidance."
                    let collectedAt = Date(timeIntervalSince1970: 172_800)
                    let subtotal = CodexRequestSubtotal(
                        totalTokens: 0,
                        requestCount: 0,
                        conflictCount: 0,
                        excludedCount: 0,
                        partial: false,
                        costUSD: 0,
                        unpricedRequestCount: 0)
                    return CodexIdentifiedResult(
                        reports: [.init(
                            host: "local",
                            source: "local",
                            collectedAt: collectedAt,
                            ledger: CodexRequestLedger(startUnixMs: start, endUnixMs: end),
                            error: nil,
                            subtotal: subtotal), .init(
                            host: hosts.first ?? "missing-host",
                            source: "ssh",
                            collectedAt: unavailable ? nil : collectedAt,
                            ledger: unavailable ? nil : CodexRequestLedger(startUnixMs: start, endUnixMs: end),
                            error: unavailable ? recovery : nil,
                            subtotal: unavailable ? nil : subtotal)],
                        subtotal: subtotal,
                        allSourcesAvailable: !unavailable,
                        partial: unavailable)
                },
                nowProvider: { Date(timeIntervalSince1970: 172_800) })
            controller.selectPeriod(.rolling(days: 2))
            let hosting = NSHostingView(rootView: MachineSpendDetail(
                settings: settings, store: store, controller: controller)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.accessibilityEnabled, true)
                .padding().frame(width: 800, height: 500))
            let window = NSWindow(
                contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 500),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { controller.stop(); window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded()
            let disclosure = try #require(Self.disclosure(in: hosting))
            disclosure.perform(#selector(NSAccessibilityProtocol.accessibilityPerformPress))
            let deadline = Date().addingTimeInterval(10)
            while controller.machineResult == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
                hosting.layoutSubtreeIfNeeded()
            }
            let result = try #require(controller.machineResult)
            let source = try #require(result.reports.last)
            try #require(source.host == "fixture-host")
            let expected = "Fixture remote recovery guidance."
            let renderDeadline = Date().addingTimeInterval(1)
            var text = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
            while !text.contains(L("Shared requests count once.")), Date() < renderDeadline {
                try await Task.sleep(for: .milliseconds(10))
                hosting.layoutSubtreeIfNeeded()
                text = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
            }
            try #require(
                text.contains("fixture-host") && text.contains(L("Shared requests count once.")),
                Comment(rawValue: text))
            if unavailable {
                try #require(text.contains(L("Unavailable")), Comment(rawValue: text))
                #expect(text.contains(expected), "The failed source row must show its collector recovery guidance.")
            } else {
                #expect(source.error == nil)
                #expect(!text.contains(expected))
            }
        }
    }

    private static func loadRequest(_: SpendDashboardRequestBuildMode) async -> SpendDashboardLoadRequest {
        SpendDashboardLoadRequest(
            configuration: .init(costUsageEnabled: false, providerIDs: [], codexAccountIdentities: []),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: Date(timeIntervalSince1970: 172_800),
            force: false)
    }

    private static func disclosure(in element: Any, depth: Int = 0) -> NSObject? {
        guard depth < 30, let element = element as? NSObject else { return nil }
        let role = #selector(NSAccessibilityProtocol.accessibilityRole)
        if element.responds(to: role),
           let value = element.perform(role)?.takeUnretainedValue() as? String,
           value == NSAccessibility.Role.disclosureTriangle.rawValue
        { return element }
        let children = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard element.responds(to: children),
              let values = element.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return values.lazy.compactMap { self.disclosure(in: $0, depth: depth + 1) }.first
    }

    private static func hostEditor(settings: SettingsStore) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AgentSessionHostsEditor(settings: settings)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.accessibilityEnabled, true)
            .padding().frame(width: 640, height: 180))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { self.textFields(in: $0) }
    }

    private static func submit(_ text: String, through field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.sendAction(field.action, to: field.target)
    }

    @Test
    func `removing and readding shared host revokes consent across reload and invalid aliases are not selectable`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        settings.agentSessionsManualHosts = "A, B"
        settings.costUsageHosts = ["A", "B"]
        settings.agentSessionsManualHosts = "B"
        settings.agentSessionsManualHosts = "A, B"
        #expect(settings.costUsageHosts == ["B"])
        defaults.set("B", forKey: "agentSessionsManualHosts")
        defaults.set(["A", "B"], forKey: "costUsageHosts")
        #expect(testSettingsStore(suiteName: #function, userDefaults: defaults).costUsageHosts == ["B"])
        settings.agentSessionsManualHosts = "A, B, bad/path"
        #expect(settings.selectableCostUsageHosts == ["A", "B"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `manual runs receive hosts and period and cancel or stop rejects late completion`() async {
        let pending = PendingMachineCollection()
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: Self.loadRequest,
            machineLoader: { hosts, days, _, _ in await pending.load(hosts, days: days) },
            nowProvider: { Date(timeIntervalSince1970: 172_800) })
        controller.selectPeriod(.rolling(days: 2))
        let cancelledCompletion = AsyncStream<Void>.makeStream()
        MachineTaskCompletion.$token.withValue(MachineTaskCompletion.Token(cancelledCompletion.continuation)) {
            controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: false)
        }
        while await pending.calls.isEmpty {
            await Task.yield()
        }
        #expect(await pending.calls.first?.0 == ["selected"])
        #expect(await pending.calls.first?.1 == 2)
        #expect(controller.machineWindow?.lowerBound == Date(timeIntervalSince1970: 86400))
        controller.cancelMachineSpend()
        await pending.finish()
        for await _ in cancelledCompletion.stream {}
        #expect(controller.machineResult == nil && !controller.machineRunning)
        controller.runMachineSpend(hosts: ["disabled"], eligible: false, localPartial: false)
        #expect(!controller.machineRunning && controller.machineWindow == nil)

        #expect(await pending.calls.count == 1)
        let stoppedCompletion = AsyncStream<Void>.makeStream()
        MachineTaskCompletion.$token.withValue(MachineTaskCompletion.Token(stoppedCompletion.continuation)) {
            controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: false)
        }
        while await pending.calls.count < 2 {
            await Task.yield()
        }
        #expect(controller.machineRunning && controller.machineWindow != nil)
        controller.stop()
        #expect(!controller.machineRunning && controller.machineWindow == nil)
        await pending.finish()
        for await _ in stoppedCompletion.stream {}
        #expect(controller.machineResult == nil)
    }
}

private actor PendingMachineCollection {
    var calls: [([String], Int)] = []
    var continuation: CheckedContinuation<CodexIdentifiedResult, Never>?
    func load(_ hosts: [String], days: Int) async -> CodexIdentifiedResult {
        self.calls.append((hosts, days))
        return await withCheckedContinuation { self.continuation = $0 }
    }

    func finish() {
        self.continuation?.resume(returning: CodexIdentifiedResult(
            reports: [.init(
                host: "local",
                source: "local",
                collectedAt: nil,
                ledger: nil,
                error: "Local native Codex identified usage is unavailable.")],
            subtotal: nil,
            allSourcesAvailable: false,
            partial: true))
        self.continuation = nil
    }
}

private enum MachineTaskCompletion {
    @TaskLocal static var token: Token?

    final class Token: Sendable {
        let continuation: AsyncStream<Void>.Continuation

        init(_ continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        deinit {
            self.continuation.finish()
        }
    }
}
