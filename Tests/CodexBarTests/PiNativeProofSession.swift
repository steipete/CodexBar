import AppKit
import Foundation
import Observation
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Observable
final class PiNativeProofSession {
    let corpus: PiNativeProofCorpus
    let settings: SettingsStore
    let store: UsageStore
    let controller: StatusItemController
    var widgetSnapshot: WidgetSnapshot?
    var statusText = "Preparing synthetic local history…"
    var busy = false
    var finished = false
    var failure: String?
    var lastAction = "startup"
    var actionNumber = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var openMenu: NSMenu?
    @ObservationIgnored var actionTask: Task<Void, Never>?

    var piEnabled: Bool {
        self.store.isEnabled(.pi)
    }

    var enabledProviders: [UsageProvider] {
        self.piEnabled ? [.claude, .pi] : [.claude]
    }

    init(output: URL) throws {
        let corpus = PiNativeProofCorpus(output: output)
        try corpus.prepare()
        self.corpus = corpus
        let saved = (try? Data(contentsOf: output.appendingPathComponent("selection.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] }
        let piEnabled = saved?["piEnabled"] ?? true
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(
            suiteName: "PiNativeProof",
            userDefaults: defaults,
            config: CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: $0 == .claude || ($0 == .pi && piEnabled))
            }),
            prepareDefaults: {
                $0.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                $0.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
                $0.set(true, forKey: "debugDisableKeychainAccess")
                $0.set(true, forKey: "providerDetectionCompleted")
                $0.set(false, forKey: "openAIWebAccessEnabled")
            })
        settings._test_codexReconciliationEnvironment = corpus.environment
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = false
        settings.openCodexUsageLogsEnabled = false
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        settings.costSummaryDisplayStyle = .both
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = true
        settings.mergedOverviewSelectedProviders = [.claude, .pi]
        self.settings = settings
        let store = UsageStore(
            fetcher: UsageFetcher(environment: corpus.environment),
            browserDetection: BrowserDetection(homeDirectory: corpus.root.path, fileExists: { _ in false }),
            costUsageFetcher: CostUsageFetcher(cacheRoot: corpus.cache),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: corpus.environment,
            widgetSnapshotURL: corpus.widgetURL)
        store._test_piHistoryScopeResolver = { _ in
            PiSessionCostScanner.scopeFingerprint(options: corpus.piOptions)
        }
        store._test_tokenUsageResultLoaderOverride = { provider, force, now, _, days, includePi in
            try await corpus.load(provider: provider, force: force, now: now, historyDays: days, includePi: includePi)
        }
        store._test_providerRefreshOverride = { [weak store] provider in
            guard provider == .claude || provider == .pi else { return XCTFail("Unexpected provider transport") }
            store?._setSnapshotForTesting(Self.usageSnapshot(), provider: provider)
        }
        self.store = store
        self.controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        let dashboard = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { mode in
                await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
            },
            publicationHandler: { [weak store] publication in store?.spendDashboardPublication = publication })
        dashboard.selectDays(30)
        store.sharedSpendDashboardControllerStorage = dashboard
        store.startSharedSpendDashboardPublication()
    }

    func run(_ action: String) {
        guard !self.busy else { return }
        self.busy = true
        self.lastAction = action
        self.actionTask = Task { @MainActor in
            do {
                let oldEvidence = self.corpus.cacheEvidence()
                switch action {
                case "toggle":
                    self.settings.setProviderEnabled(
                        provider: .pi, metadata: self.store.metadata(for: .pi), enabled: !self.piEnabled)
                case "offline": try self.corpus.makeOffline()
                case "restore-append": try self.corpus.restoreAndAppend()
                default: break
                }
                try await self.refresh()
                if action == "offline" {
                    let oldCache = try XCTUnwrap(oldEvidence["sha256"] as? String)
                    XCTAssertFalse(oldCache.isEmpty)
                    let oldScanMilliseconds = try XCTUnwrap(oldEvidence["lastScanUnixMs"] as? Double)
                    let retained = try XCTUnwrap(self.store.tokenSnapshotForCurrentProviderConfig(for: .pi)?.snapshot)
                    XCTAssertEqual(
                        retained.updatedAt.timeIntervalSince1970,
                        oldScanMilliseconds / 1000,
                        accuracy: 0.002)
                    XCTAssertFalse(retained.historyCoverageIsEstablished)
                    let widgetPi = self.widgetSnapshot?.entries.first { $0.provider == UsageProvider.pi.instanceID }
                    let widgetDate = try XCTUnwrap(widgetPi?.updatedAt)
                    // Shared widget JSON encodes ISO 8601 dates at whole-second precision.
                    XCTAssertEqual(widgetDate.timeIntervalSince1970, floor(oldScanMilliseconds / 1000))
                    XCTAssertEqual(self.corpus.cacheEvidence()["sha256"] as? String, oldCache)
                }
                if !self.corpus.isOffline {
                    self.verifyTotals()
                }
                let selection = try JSONSerialization.data(withJSONObject: ["piEnabled": self.piEnabled])
                try selection.write(to: self.corpus.output.appendingPathComponent("selection.json"), options: .atomic)
                self.statusText = "\(action) complete · Pi \(self.piEnabled ? "enabled" : "disabled")"
            } catch {
                self.failure = error.localizedDescription
                self.statusText = "Proof failed: \(error.localizedDescription)"
                XCTFail(self.statusText)
            }
            self.busy = false
            self.actionNumber += 1
            self.record(archive: true)
        }
    }

    private func refresh() async throws {
        for provider in self.enabledProviders {
            self.store._setSnapshotForTesting(Self.usageSnapshot(), provider: provider)
        }
        for provider in [UsageProvider.claude, .pi] {
            await self.store.refreshTokenUsage(provider, force: true)
        }
        let dashboard = self.store.sharedSpendDashboardController()
        dashboard.update(configuration: SpendDashboardSource.configuration(settings: self.settings, store: self.store))
        dashboard.refresh()
        let deadline = Date().addingTimeInterval(30)
        while dashboard.isRefreshing || self.store.sharedSpendDashboardTokenPublicationDebounceTask != nil ||
            self.store.sharedSpendDashboardObservationDebounceTask != nil ||
            !self.store.spendDashboardTokenRefreshInFlight.isEmpty
        {
            try Task.checkCancellation()
            guard Date() < deadline else { throw CocoaError(.coderReadCorrupt) }
            try await Task.sleep(for: .milliseconds(25))
        }
        self.store.persistWidgetSnapshot(reason: "pi-native-proof")
        await self.store.widgetSnapshotPersistTask?.value
        self.widgetSnapshot = WidgetSnapshotStore.load(from: self.corpus.widgetURL)
        XCTAssertNotNil(self.widgetSnapshot)
    }

    func showMenu(provider: UsageProvider?) {
        guard !self.busy, let view = window?.contentView else { return }
        self.settings.mergedMenuLastSelectedWasOverview = provider == nil
        if let provider { self.settings.selectedMenuProvider = provider.instanceID }
        self.openMenu = self.controller.makeMenu(for: provider)
        self.lastAction = provider == nil ? "overview-menu" : "pi-menu"
        self.actionNumber += 1
        record(archive: true)
        let top = view.isFlipped ? 65 : view.bounds.height - 65
        self.openMenu?.popUp(positioning: nil, at: NSPoint(x: 20, y: top), in: view)
        record(archive: true)
    }

    func finish() {
        guard !self.busy else { return }
        self.lastAction = "finish"
        self.actionNumber += 1
        record(archive: true)
        self.finished = true
    }

    func stop() {
        self.actionTask?.cancel()
        self.openMenu?.cancelTracking()
        self.store.stopSharedSpendDashboardPublication()
        self.store.sharedSpendDashboardControllerStorage = nil
        self.controller.releaseStatusItemsForTesting()
    }

    private func verifyTotals() {
        let model = self.controller.overviewSpendDashboardModel(providers: self.enabledProviders)
        XCTAssertEqual(model.groups.compactMap(\.totalTokens).reduce(0, +), self.corpus.hasAppended ? 250_000 : 240_000)
        XCTAssertEqual(
            model.groups.compactMap(\.totalCost).reduce(0, +),
            self.corpus.hasAppended ? 0.75 : 0.72,
            accuracy: 0.000_001)
        if self.piEnabled {
            let pi = self.widgetSnapshot?.entries.first { $0.provider == UsageProvider.pi.instanceID }
            XCTAssertNotNil(pi)
            XCTAssertNil(pi?.primary)
            XCTAssertTrue(pi?.usageRows?.isEmpty ?? true)
            XCTAssertEqual(pi?.tokenUsage?.last30DaysTokens, self.corpus.hasAppended ? 50000 : 40000)
        }
    }

    private static func usageSnapshot() -> UsageSnapshot {
        UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date(), dataConfidence: .estimated)
    }
}
