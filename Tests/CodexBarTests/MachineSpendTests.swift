import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
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
        let (settings, store) = Self.machineFixture(
            root: root, suiteName: #function, defaults: InMemoryUserDefaults())
        settings.hidePersonalInfo = false
        settings.agentSessionsManualHosts = "fixture-host"
        settings.setCostUsageHost("fixture-host", enabled: true)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
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

    private static func machineFixture(
        root: URL, suiteName: String, defaults: InMemoryUserDefaults) -> (SettingsStore, UsageStore)
    {
        let settings = testSettingsStore(
            suiteName: suiteName, userDefaults: defaults, config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.codex], settings: settings)
        settings.costUsageEnabled = true
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
        return (settings, store)
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

    @Test(.timeLimit(.minutes(1)), arguments: MachineHostRevocation.allCases)
    func `machine launch projects consent and cancels revoked collections before spawn`(
        revocation: MachineHostRevocation) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryUserDefaults(values: [
            "agentSessionsManualHosts": "fixture-host", "costUsageHosts": ["fixture-host"],
        ])
        let lockURL = root.appendingPathComponent("hosts.lock")
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: defaults,
            config: testConfigWithAllProvidersDisabled(),
            hostPreferencesLockURL: lockURL)
        let childEnvironment = ["PATH": "/usr/bin:/bin"]
        let marker = root.appendingPathComponent("spawned")
        let launchPending = LockIsolated(false)
        let resume = AsyncStream<Void>.makeStream()
        let loader = SpendDashboardController.makeMachineLoader(
            launchRemote: settings.spendHostLaunch,
            local: { start, end in CodexRequestLedger(startUnixMs: start, endUnixMs: end) },
            fetchRemote: { _, _, start, end, launch in
                let ledger = try JSONEncoder().encode(CodexRequestLedger(startUnixMs: start, endUnixMs: end))
                let json = try #require(String(data: ledger, encoding: .utf8))
                let output = try await SubprocessRunner.run(
                    binary: "/bin/sh",
                    arguments: [
                        "-c",
                        "set -eu; : > \"$1\"; printf '%s\\n' \"$2\"",
                        "fixture",
                        marker.path,
                        json,
                    ],
                    environment: childEnvironment,
                    timeout: 5,
                    maxOutputBytes: 4096,
                    currentDirectoryURL: root,
                    launch: { operation in
                        launchPending.setValue(true)
                        for await _ in resume.stream {}
                        try await launch(operation)
                    },
                    label: "contained machine launch fixture")
                return try JSONDecoder().decode(CodexRequestLedger.self, from: Data(output.stdout.utf8))
            })
        let recordedOutcome = LockIsolated<Result<CodexIdentifiedResult, any Error>?>(nil)
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: Self.loadRequest,
            machineLoader: { hosts, days, start, end in
                do {
                    let result = try await loader(hosts, days, start, end)
                    recordedOutcome.setValue(.success(result))
                    return result
                } catch {
                    recordedOutcome.setValue(.failure(error))
                    throw error
                }
            })
        defer { resume.continuation.finish(); controller.stop(); settings.configFileWatcher?.stop() }
        controller.runMachineSpend(hosts: ["fixture-host"], eligible: true, localPartial: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !launchPending.value, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        var removalError: (any Error)?
        if revocation != .control {
            do {
                let removed = try HostPreferences.update(in: defaults, lockURL: lockURL) {
                    $0 = try HostPreferences.removing(
                        "fixture-host", from: $0, costOnly: revocation == .costOnly).state
                }
                #expect(removed.state.costUsageHosts.isEmpty)
                #expect(removed.state.manualHosts == (revocation == .fullRemoval ? [] : ["fixture-host"]))
            } catch { removalError = error }
        }
        #expect(settings.costUsageHosts == ["fixture-host"], "No notification refreshed Settings.")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "The same invocation is paused before spawn.")
        #expect(controller.machineRunning, "No explicit cancellation occurred while process launch was paused.")
        resume.continuation.finish()
        try await SpendDashboardStateWait.until { !controller.machineRunning }
        let outcome = try #require(recordedOutcome.value)
        if let removalError { throw removalError }
        try #require(launchPending.value, "The allowed host must reach the shared process-launch boundary.")
        if revocation != .control {
            #expect(!FileManager.default.fileExists(atPath: marker.path), "Committed revocation must prevent spawn.")
            switch outcome {
            case .success:
                Issue.record("The collection must cancel when revocation committed before process launch.")
            case let .failure(error):
                #expect(error is CancellationError)
            }
            #expect(settings.agentSessionsManualHosts == (revocation == .fullRemoval ? "" : "fixture-host"))
            #expect(settings.selectableCostUsageHosts == (revocation == .fullRemoval ? [] : ["fixture-host"]))
            #expect(settings.costUsageHosts.isEmpty)
            #expect(controller.machineResult == nil, "A cancelled run publishes neither reports nor SSH error rows.")
            #expect(!controller.machineRunning)
        } else {
            #expect(FileManager.default.fileExists(atPath: marker.path), "The allowed control must actually spawn.")
            _ = try outcome.get()
            let result = try #require(controller.machineResult)
            #expect(result.allSourcesAvailable && result.reports.map(\.host) == ["local", "fixture-host"])
            #expect(result.reports.allSatisfy { $0.error == nil })
            #expect(settings.agentSessionsManualHosts == "fixture-host")
            #expect(settings.costUsageHosts == ["fixture-host"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `manual machine run respects a committed CLI revocation before notification`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryUserDefaults(values: [
            "agentSessionsManualHosts": "devbox,mini", "costUsageHosts": ["devbox", "mini"],
        ])
        let (settings, store) = Self.machineFixture(root: root, suiteName: #function, defaults: defaults)
        let received = LockIsolated<[String]?>(nil)
        let pending = PendingMachineCollection()
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: Self.loadRequest,
            machineLoader: { hosts, days, _, _ in
                received.setValue(hosts)
                return await pending.load(hosts, days: days)
            })
        defer {
            controller.stop()
            store.stopSharedSpendDashboardPublication()
            settings.configFileWatcher?.stop()
        }
        _ = try CodexBarCLI.configHostsMutation(.remove, host: "devbox", cost: true, in: defaults, lockURL: nil)
        try #require(settings.costUsageHosts == ["devbox", "mini"], "No notification was delivered.")
        MachineSpendDetail(settings: settings, store: store, controller: controller).run()
        try #require(controller.machineRunning && controller.machineRequestedHosts == ["mini"])
        while await pending.calls.isEmpty {
            await Task.yield()
        }
        await pending.finish()
        try await SpendDashboardStateWait.until { controller.machineResult != nil }
        #expect(received.value == ["mini"])
        #expect(settings.costUsageHosts == ["mini"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `period and host changes preserve same runs while cancellation and stop reject late results`() async throws {
        let pending = PendingMachineCollection()
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: Self.loadRequest,
            machineLoader: { hosts, days, _, _ in await pending.load(hosts, days: days) },
            nowProvider: { Date(timeIntervalSince1970: 172_800) })
        controller.selectPeriod(.rolling(days: 2))
        controller.runMachineSpend(hosts: ["previous"], eligible: true, localPartial: false)
        while await pending.calls.isEmpty {
            await Task.yield()
        }
        await pending.finish()
        try await SpendDashboardStateWait.until { controller.machineResult != nil }
        try #require(controller.machineResult?.reports.contains { $0.host == "previous" } == true)
        let cancelledCompletion = AsyncStream<Void>.makeStream()
        MachineTaskCompletion.$token.withValue(MachineTaskCompletion.Token(cancelledCompletion.continuation)) {
            controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: false)
        }
        #expect(
            controller.machineResult == nil,
            "Prior-host rows must disappear while the changed-host run is pending.")
        while await pending.calls.count < 2 {
            await Task.yield()
        }
        #expect(await pending.calls.last?.0 == ["selected"])
        #expect(await pending.calls.last?.1 == 2)
        #expect(controller.machineWindow?.lowerBound == Date(timeIntervalSince1970: 86400))
        // A deferred SwiftUI onChange from pre-run projection must keep this same-host request.
        controller.reconcileMachineSpendHosts(["selected"])
        #expect(controller.machineRunning && controller.machineRequestedHosts == ["selected"])
        controller.cancelMachineSpend()
        #expect(!controller.machineRunning && controller.machineRequestedHosts == nil)
        await pending.finish()
        for await _ in cancelledCompletion.stream {}
        #expect(controller.machineResult == nil && !controller.machineRunning)
        controller.runMachineSpend(hosts: ["disabled"], eligible: false, localPartial: false)
        #expect(!controller.machineRunning && controller.machineWindow == nil)

        let reconciledCompletion = AsyncStream<Void>.makeStream()
        MachineTaskCompletion.$token.withValue(MachineTaskCompletion.Token(reconciledCompletion.continuation)) {
            controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: false)
        }
        while await pending.calls.count < 3 {
            await Task.yield()
        }
        controller.reconcileMachineSpendHosts([])
        #expect(!controller.machineRunning && controller.machineRequestedHosts == nil)
        await pending.finish()
        for await _ in reconciledCompletion.stream {}
        #expect(controller.machineResult == nil && !controller.machineRunning)

        #expect(await pending.calls.count == 3)
        let stoppedCompletion = AsyncStream<Void>.makeStream()
        MachineTaskCompletion.$token.withValue(MachineTaskCompletion.Token(stoppedCompletion.continuation)) {
            controller.runMachineSpend(hosts: ["selected"], eligible: true, localPartial: false)
        }
        while await pending.calls.count < 4 {
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

enum MachineHostRevocation: CaseIterable {
    case control, fullRemoval, costOnly
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
            reports: (["local"] + (self.calls.last?.0 ?? [])).map { host in
                .init(
                    host: host,
                    source: host == "local" ? "local" : "ssh",
                    collectedAt: nil,
                    ledger: nil,
                    error: host == "local" ? "Local native Codex identified usage is unavailable." :
                        "Fixture unavailable.")
            },
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
