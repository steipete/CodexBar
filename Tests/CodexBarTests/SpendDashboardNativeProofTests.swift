import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in proof of the production Settings > Usage & Spend pane.
///
/// The host uses disposable settings and synthetic spend history. It never starts provider
/// transports or reads real credentials, sessions, browser data, or local usage logs.
@MainActor
final class SpendDashboardNativeProofTests: XCTestCase {
    // This deliberately keeps the isolated app/window lifecycle in one proof flow.
    // swiftlint:disable:next function_body_length
    func test_nativePreferencesInteractions() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["CODEXBAR_SPEND_NATIVE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SPEND_NATIVE_PROOF_DIR for isolated native UI proof.")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil
        else {
            return XCTFail("Native proof requires credential, session, and Keychain isolation.")
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = testSettingsStore(
            suiteName: "SpendDashboardNativeProofTests",
            config: CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: $0 == .cursor || $0 == .opencode)
            }),
            prepareDefaults: {
                $0.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                $0.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
                $0.set(true, forKey: "debugDisableKeychainAccess")
                $0.set(true, forKey: "providerDetectionCompleted")
                $0.set(false, forKey: "openAIWebAccessEnabled")
            })
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.preferredCurrencyCode = "USD"
        settings.costUsageBucketTimeZoneIdentifier = "UTC"

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_providerRefreshOverride = { provider in
            XCTFail("Native proof must not start a provider transport: \(provider.rawValue)")
        }
        store._test_widgetSnapshotSaveOverride = { _ in }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_widgetSnapshotSaveOverride = nil
            store.stopSharedSpendDashboardPublication()
        }

        let now = Date()
        let configuration = SpendDashboardSource.configuration(settings: settings, store: store)
        let inputs = Self.syntheticInputs(now: now, calendar: configuration.bucketCalendar)
        let controllerDefaults = try XCTUnwrap(
            UserDefaults(suiteName: "SpendDashboardNativeProofTests-controller-\(UUID().uuidString)"))
        let controller = SpendDashboardController(
            userDefaults: controllerDefaults,
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: inputs,
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: now,
                    force: mode.forcesLoader)
            },
            loader: { request in
                SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
            },
            nowProvider: { now },
            publicationHandler: { publication in
                store.spendDashboardPublication = publication
            })
        store.sharedSpendDashboardControllerStorage = controller
        controller.selectDays(7)
        controller.update(configuration: configuration)
        try self.waitUntil { !controller.isRefreshing && !controller.model.groups.isEmpty }
        controller.selectDay(now)
        XCTAssertNotNil(controller.selectedDay)
        XCTAssertFalse(controller.model.groups.first?.hourlyPoints.isEmpty ?? true)

        let application = NSApplication.shared
        guard application.delegate == nil, UserDefaults.standard.object(forKey: "NSOpen") == nil else {
            return XCTFail("Native proof requires a standalone test application.")
        }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let selectionDefaults = try XCTUnwrap(
            UserDefaults(suiteName: "SpendDashboardNativeProofTests-selection-\(UUID().uuidString)"))
        let selection = PreferencesSelection(userDefaults: selectionDefaults)
        let settingsWindow = SettingsWindowController(
            selection: selection,
            makeWindow: {
                let rootView = PreferencesView(
                    settings: settings,
                    store: store,
                    cloudSyncState: CloudSyncState(),
                    updater: DisabledUpdaterController(),
                    selection: selection)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1120, height: 900),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false)
                window.contentViewController = NSHostingController(rootView: rootView)
                window.title = selection.pane.title
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.isReleasedWhenClosed = false
                window.center()
                return window
            },
            prepareToPresent: {},
            registerWindow: { _ in },
            presentWindow: { window in
                window.makeKeyAndOrderFront(nil)
            },
            didPresentWindow: { _ in },
            presentationFailed: {
                XCTFail("Could not present the isolated Usage & Spend proof window")
            })
        defer {
            controller.stop()
            settingsWindow.close()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }

        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        XCTAssertEqual(settingsWindow.open(pane: .usageSpend), .created)
        let window = try XCTUnwrap(settingsWindow.window)
        try self.waitUntil { window.isVisible }
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        try self.writeReceipt(
            name: "initial",
            window: window,
            selection: selection,
            controller: controller,
            directory: directory)
        try self.writeAccessibilityDump(window: window, directory: directory)
        try self.press(label: "Day", inside: "spend-dashboard-trend-picker")
        try self.press(label: "Hour", inside: "spend-dashboard-trend-picker")
        try self.press(label: "Projects", inside: "spend-dashboard-detail-picker")
        try self.press(label: "Providers", inside: "spend-dashboard-detail-picker")
        self.pumpEvents()
        try self.writeReceipt(
            name: "selectors",
            window: window,
            selection: selection,
            controller: controller,
            directory: directory)
        try self.writeScreenshot(name: "native-selectors", window: window, directory: directory)

        try self.press(identifier: "spend-dashboard-clear-selected-day")
        try self.waitUntil { controller.selectedDay == nil }
        try self.writeReceipt(
            name: "selected-day-cleared",
            window: window,
            selection: selection,
            controller: controller,
            directory: directory)
        try self.writeScreenshot(name: "native-selected-day-cleared", window: window, directory: directory)

        try self.press(identifier: "spend-dashboard-data-controls")
        self.pumpEvents()
        XCTAssertNotNil(self.element(label: "Copy JSON"))
        self.scrollMainPaneToBottom(window)
        self.pumpEvents()
        try self.writeReceipt(
            name: "data-controls-expanded",
            window: window,
            selection: selection,
            controller: controller,
            directory: directory)
        try self.writeScreenshot(name: "native-data-controls-expanded", window: window, directory: directory)
    }

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard condition() else {
            throw NSError(domain: "SpendDashboardNativeProof", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for the isolated native proof state.",
            ])
        }
    }

    private func press(label: String, inside identifier: String) throws {
        let container = try XCTUnwrap(
            self.element(identifier: identifier),
            "Missing native control group \(identifier)")
        let target = try XCTUnwrap(
            self.accessibilityElements(from: container).first { element in
                self.accessibilityString(element, attribute: kAXTitleAttribute) == label
                    || self.accessibilityString(element, attribute: kAXDescriptionAttribute) == label
                    || self.accessibilityString(element, attribute: kAXValueAttribute) == label
            },
            "Missing \(label) inside \(identifier)")
        XCTAssertEqual(AXUIElementPerformAction(target, kAXPressAction as CFString), .success)
        self.pumpEvents()
    }

    private func press(identifier: String) throws {
        let target = try XCTUnwrap(self.element(identifier: identifier), "Missing native control \(identifier)")
        XCTAssertEqual(AXUIElementPerformAction(target, kAXPressAction as CFString), .success)
        self.pumpEvents()
    }

    private func element(label: String) -> AXUIElement? {
        self.accessibilityElements().first { element in
            self.accessibilityString(element, attribute: kAXTitleAttribute) == label
                || self.accessibilityString(element, attribute: kAXDescriptionAttribute) == label
                || self.accessibilityString(element, attribute: kAXValueAttribute) == label
        }
    }

    private func element(identifier: String) -> AXUIElement? {
        self.accessibilityElements().first {
            self.accessibilityString($0, attribute: kAXIdentifierAttribute) == identifier
        }
    }

    private func accessibilityElements() -> [AXUIElement] {
        self.accessibilityElements(from: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
    }

    private func accessibilityElements(from root: AXUIElement) -> [AXUIElement] {
        var queue = [root]
        var result: [AXUIElement] = []
        while !queue.isEmpty {
            let element = queue.removeFirst()
            result.append(element)
            queue.append(contentsOf: self.accessibilityChildren(element))
        }
        return result
    }

    private func accessibilityChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return [] }
        return children
    }

    private func accessibilityString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func scrollMainPaneToBottom(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let scrollViews = self.subviews(from: contentView).compactMap { $0 as? NSScrollView }
        guard let scrollView = scrollViews.max(by: { $0.frame.width < $1.frame.width }),
              let documentView = scrollView.documentView
        else { return }
        let offset = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func subviews(from root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(self.subviews(from:))
    }

    private func pumpEvents() {
        let application = NSApplication.shared
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if let event = application.nextEvent(
                matching: .any,
                until: Date().addingTimeInterval(0.01),
                inMode: .default,
                dequeue: true)
            {
                application.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func writeReceipt(
        name: String,
        window: NSWindow,
        selection: PreferencesSelection,
        controller: SpendDashboardController,
        directory: URL) throws
    {
        let receipt: [String: String] = [
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "window": String(window.windowNumber),
            "pane": selection.pane.persistenceToken,
            "selectedDays": String(controller.selectedDays),
            "selectedDay": controller.selectedDay == nil ? "none" : "set",
            "groups": String(controller.model.groups.count),
        ]
        try JSONEncoder().encode(receipt).write(
            to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }

    private func writeScreenshot(name: String, window: NSWindow, directory: URL) throws {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let view = try XCTUnwrap(window.contentView)
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private func writeAccessibilityDump(window: NSWindow, directory: URL) throws {
        _ = window
        let lines = self.accessibilityElements().map { element in
            let role = self.accessibilityString(element, attribute: kAXRoleAttribute) ?? "-"
            let identifier = self.accessibilityString(element, attribute: kAXIdentifierAttribute) ?? "-"
            let title = self.accessibilityString(element, attribute: kAXTitleAttribute) ?? "-"
            let description = self.accessibilityString(element, attribute: kAXDescriptionAttribute) ?? "-"
            let value = self.accessibilityString(element, attribute: kAXValueAttribute) ?? "-"
            return "\(role)\t\(identifier)\t\(title)\t\(description)\t\(value)"
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("accessibility.txt"),
            atomically: true,
            encoding: .utf8)
    }

    private static func syntheticInputs(
        now: Date,
        calendar: Calendar) -> [SpendDashboardModel.ProviderInput]
    {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let earlier = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        let cursorDaily = [
            self.entry(day: earlier, calendar: calendar, cost: 4.20, tokens: 8_200_000, model: "example-large"),
            self.entry(day: yesterday, calendar: calendar, cost: 7.80, tokens: 12_400_000, model: "example-fast"),
            self.entry(day: today, calendar: calendar, cost: 9.60, tokens: 15_800_000, model: "example-large"),
        ]
        let openCodeDaily = [
            self.entry(day: yesterday, calendar: calendar, cost: 1.25, tokens: 2_400_000, model: "sample-coder"),
            self.entry(day: today, calendar: calendar, cost: 2.40, tokens: 4_100_000, model: "sample-coder"),
        ]
        let hours = [9, 11, 14, 16, 18].compactMap { hour -> CostUsageHourlyEntry? in
            guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) else { return nil }
            return CostUsageHourlyEntry(hour: date, totalTokens: 820_000, costUSD: Double(hour - 7) * 0.12)
        }
        let project = CostUsageProjectBreakdown(
            name: "example-dashboard",
            path: "/Users/example/Projects/example-dashboard",
            totalTokens: 4_100_000,
            totalCostUSD: 2.40,
            daily: openCodeDaily,
            modelBreakdowns: nil)
        let session = CostUsageSessionBreakdown(
            sessionID: "synthetic-session-001",
            lastActivity: now,
            inputTokens: 2_600_000,
            cachedInputTokens: 1_200_000,
            outputTokens: 300_000,
            reasoningTokens: 120_000,
            totalTokens: 4_100_000,
            requestCount: 18,
            costUSD: 2.40,
            modelBreakdowns: [])
        return [
            SpendDashboardModel.ProviderInput(
                provider: .cursor,
                displayName: "Cursor",
                snapshot: self.snapshot(entries: cursorDaily, now: now, metered: 18.50)),
            SpendDashboardModel.ProviderInput(
                provider: .opencode,
                displayName: "OpenCode",
                snapshot: self.snapshot(
                    entries: openCodeDaily,
                    now: now,
                    projects: [project],
                    sessions: [session],
                    hourly: hours)),
        ]
    }

    private static func snapshot(
        entries: [CostUsageDailyReport.Entry],
        now: Date,
        metered: Double? = nil,
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        hourly: [CostUsageHourlyEntry] = []) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: entries.last?.totalTokens,
            sessionCostUSD: entries.last?.costUSD,
            last30DaysTokens: entries.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: entries.compactMap(\.costUSD).reduce(0, +),
            historyDays: 365,
            historyCoverageIsEstablished: true,
            meteredCostUSD: metered,
            costProvenance: metered == nil ? .listPriceEstimate : .mixed,
            daily: entries,
            projects: projects,
            sessions: sessions,
            hourly: hourly,
            updatedAt: now)
    }

    private static func entry(
        day: Date,
        calendar: Calendar,
        cost: Double,
        tokens: Int,
        model: String) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: CostUsageScanner.CostUsageDayRange.dayKey(from: day, calendar: calendar),
            inputTokens: tokens * 6 / 10,
            outputTokens: tokens / 10,
            cacheReadTokens: tokens * 3 / 10,
            reasoningTokens: tokens / 20,
            totalTokens: tokens,
            requestCount: 12,
            costUSD: cost,
            modelsUsed: [model],
            modelBreakdowns: [
                .init(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: tokens,
                    requestCount: 12,
                    inputTokens: tokens * 6 / 10,
                    outputTokens: tokens / 10,
                    cacheReadTokens: tokens * 3 / 10,
                    reasoningTokens: tokens / 20),
            ],
            pricedRequestCount: 12)
    }
}
