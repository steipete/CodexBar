import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class SpendDashboardNativeProofTests: XCTestCase {
    func test_interactiveSyntheticDashboard() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_SPEND_NATIVE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SPEND_NATIVE_PROOF_DIR for signed native computer-use proof")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Use an isolated test host") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = testSettingsStore(
            suiteName: "SpendDashboardNativeProof",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        enableTestProviders([.cursor, .opencode], settings: settings)
        settings.statusChecksEnabled = false
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
        store._test_providerRefreshOverride = { _ in XCTFail("Synthetic proof must not start a provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        let now = Date()
        let configuration = SpendDashboardSource.configuration(settings: settings, store: store)
        let inputs = Self.syntheticInputs(now: now, calendar: configuration.bucketCalendar)
        let controller = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
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
            publicationHandler: { store.spendDashboardPublication = $0 })
        store.sharedSpendDashboardControllerStorage = controller
        controller.selectPeriod(.rolling(days: 7))
        controller.update(configuration: configuration)
        try await SpendDashboardStateWait.until { !controller.isRefreshing && !controller.model.groups.isEmpty }
        controller.selectDay(now)
        defer {
            controller.stop()
            store.stopSharedSpendDashboardPublication()
            settings.configFileWatcher?.stop()
        }
        let application = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousPolicy = application.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Usage & Spend"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            SpendDashboardPane(settings: settings, store: store)
            HStack {
                Text("Synthetic data only").foregroundStyle(.secondary)
                Spacer()
                Button("Toggle privacy") { settings.hidePersonalInfo.toggle() }
                Button("Finish proof") {
                    FileManager.default.createFile(atPath: output.appendingPathComponent("done").path, contents: Data())
                }
            }.padding(12)
        }.environment(\.locale, Locale(identifier: "en_US")))
        defer {
            window.close()
            _ = application.setActivationPolicy(previousPolicy)
            previousApplication?.activate()
        }
        _ = application.setActivationPolicy(.regular)
        application.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(480)
        repeat {
            let receipt: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "window": window.windowNumber,
                "syntheticOnly": true,
                "selectedDays": controller.model.requestedDays,
                "selectedDay": controller.selectedDay == nil ? "none" : "set",
                "privacy": settings.hidePersonalInfo,
                "groups": controller.model.groups.count,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                .write(to: output.appendingPathComponent("state.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path) { return }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        XCTFail("Native proof did not finish before its deadline")
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
        var openCodeDaily = [
            self.entry(day: yesterday, calendar: calendar, cost: 1.25, tokens: 2_400_000, model: "sample-coder"),
            self.entry(day: today, calendar: calendar, cost: 2.40, tokens: 4_100_000, model: "sample-coder"),
        ]
        openCodeDaily += (1...7).map {
            self.entry(day: today, calendar: calendar, cost: 0.1, tokens: 100, model: "sample-model-\($0)")
        }
        openCodeDaily.append(CostUsageDailyReport.Entry(
            date: CostUsageScanner.CostUsageDayRange.dayKey(from: today, calendar: calendar),
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: [.init(
                modelName: "sample-incomplete", costUSD: nil, totalTokens: nil, incompleteRequestCount: 1)]))
        let hours = [9, 11, 14, 16, 18].compactMap { hour -> CostUsageHourlyEntry? in
            guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) else { return nil }
            return CostUsageHourlyEntry(hour: date, totalTokens: 820_000, costUSD: Double(hour - 7) * 0.12)
        }
        let project = CostUsageProjectBreakdown(
            name: "example-dashboard",
            path: "/Users/example/Projects/example-dashboard",
            totalTokens: cursorDaily.compactMap(\.totalTokens).reduce(0, +),
            totalCostUSD: cursorDaily.compactMap(\.costUSD).reduce(0, +),
            daily: cursorDaily,
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
                snapshot: self.snapshot(entries: cursorDaily, now: now, metered: 18.50, projects: [project])),
            SpendDashboardModel.ProviderInput(
                provider: .opencode,
                displayName: "OpenCode",
                snapshot: self.snapshot(
                    entries: openCodeDaily,
                    now: now,
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
