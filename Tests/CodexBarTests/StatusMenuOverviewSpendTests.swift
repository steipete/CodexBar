import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `native overview share menu opens filtered preview`() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["CODEXBAR_OVERVIEW_SHARE_PROOF_DIR"] else { return }
        let language = environment["CODEXBAR_OVERVIEW_SHARE_PROOF_LANGUAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "en"
        guard ["en", "de"].contains(language) else {
            Issue.record("CODEXBAR_OVERVIEW_SHARE_PROOF_LANGUAGE must be en or de")
            return
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL
        let outputDirectory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        let testProcess = SettingsStore.isRunningTests
        let flags = environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1" &&
            environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1" &&
            environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1" &&
            environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        let homeBelowTmp = self.isStrictDescendant(home, of: temporaryDirectory)
        let outputBelowHome = self.isStrictDescendant(outputDirectory, of: home)
        let noDelegate = NSApplication.shared.delegate == nil
        guard testProcess, flags, homeBelowTmp, outputBelowHome, noDelegate
        else {
            Issue.record("""
            Native share proof requires isolated standalone test application:
            testprocess=\(testProcess) flags=\(flags) homeBelowTmp=\(homeBelowTmp)
            outputBelowHome=\(outputBelowHome) noDelegate=\(noDelegate)
            """)
            return
        }

        let application = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousPolicy = application.activationPolicy()
        try #require(application.setActivationPolicy(.regular))
        application.finishLaunching()
        defer {
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }

        let settings = testSettingsStore(
            suiteName: "StatusMenuOverviewSpendTests-native-share",
            userDefaults: InMemoryUserDefaults(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = true
        settings.spendDashboardHiddenSourceIDs = ["claude:hidden"]
        enableTestProviders([.codex, .claude], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let now = Date()
        let components = settings.costUsageBucketCalendar.dateComponents([.year, .month, .day], from: now)
        let year = try #require(components.year)
        let month = try #require(components.month)
        let dayOfMonth = try #require(components.day)
        let date = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        func input(id: String, provider: UsageProvider, cost: Double) -> SpendDashboardModel.ProviderInput {
            SpendDashboardModel.ProviderInput(
                id: id,
                provider: provider,
                displayName: id,
                snapshot: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: 10,
                    last30DaysCostUSD: cost,
                    daily: [CostUsageDailyReport.Entry(
                        date: date,
                        inputTokens: 5,
                        outputTokens: 5,
                        totalTokens: 10,
                        costUSD: cost,
                        modelsUsed: nil,
                        modelBreakdowns: nil)],
                    updatedAt: now))
        }
        let inputs = [
            input(id: "codex:visible", provider: .codex, cost: 2),
            input(id: "claude:hidden", provider: .claude, cost: 900),
        ]
        store.spendDashboardPublication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: SpendDashboardSource.configuration(settings: settings, store: store),
            loadedAt: now,
            isRefreshing: false,
            inputs: inputs,
            sources: inputs.map {
                SpendSourcePublication(
                    id: $0.id,
                    provider: $0.provider,
                    displayName: $0.displayName,
                    role: .subscription,
                    state: .available)
            })
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
            try self.openOverviewPreviewAndCapture(
                controller: controller,
                outputDirectory: outputDirectory,
                environment: environment,
                language: language)
        }
    }

    private func openOverviewPreviewAndCapture(
        controller: StatusItemController,
        outputDirectory: URL,
        environment: [String: String],
        language: String) throws
    {
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let item = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewShareStats"
        })
        #expect(item.title == L("Share Usage Snapshot…", language: language))
        let target = try #require(item.target)
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: target, from: item))

        let preview = try #require(NSApplication.shared.windows.compactMap {
            $0.windowController as? ShareStatsWindowController
        }.first { $0.window?.isVisible == true })
        defer { preview.close() }
        #expect(preview.payload.providers.map(\.providerName) == ["codex:visible"])
        #expect(preview.payload.currencies.first?.estimatedCost == 2)
        try self.capturePreviewAndOptionallyCopy(
            preview,
            outputDirectory: outputDirectory,
            environment: environment,
            language: language)
    }

    private func capturePreviewAndOptionallyCopy(
        _ preview: ShareStatsWindowController,
        outputDirectory: URL,
        environment: [String: String],
        language: String) throws
    {
        let window = try #require(preview.window)
        #expect(window.isVisible)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(content.bounds.width > 0)
        #expect(content.bounds.height > 0)
        if environment["CODEXBAR_OVERVIEW_EXTERNAL_PROOF"] == "1" {
            try self.waitForOverviewShareInspection(
                window: window,
                outputDirectory: outputDirectory,
                language: language)
        }
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(
            to: outputDirectory.appendingPathComponent("overview-share-preview\(Self.localeSuffix(language)).png"),
            options: .atomic)

        let windowCaptureEnabled = environment["CODEXBAR_OVERVIEW_WINDOW_CAPTURE"] == "1"
        if windowCaptureEnabled {
            guard environment["CI"] == "true" else {
                Issue.record("CODEXBAR_OVERVIEW_WINDOW_CAPTURE=1 requires CI=true")
                return
            }
            Self.captureWindow(
                window,
                to: outputDirectory.appendingPathComponent("overview-share-window\(Self.localeSuffix(language)).png"))
        }

        guard environment["CODEXBAR_OVERVIEW_COPY_BUTTON_PROOF"] == "1" else { return }
        guard environment["CI"] == "true" else {
            Issue
                .record(
                    "CODEXBAR_OVERVIEW_COPY_BUTTON_PROOF=1 requires CI=true before writing to the general pasteboard")
            return
        }
        let pasteboard = NSPasteboard.general
        let changeCountBeforeCopy = pasteboard.changeCount
        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36))
        #expect(window.performKeyEquivalent(with: returnKey))
        #expect(pasteboard.changeCount > changeCountBeforeCopy)
        let copiedPNG = try #require(pasteboard.data(forType: .png))
        let copiedTIFF = try #require(pasteboard.data(forType: .tiff))
        let copiedBitmap = try #require(NSBitmapImageRep(data: copiedPNG))
        #expect(copiedPNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(!copiedTIFF.isEmpty)
        #expect(copiedBitmap.pixelsWide == 1200)
        #expect(copiedBitmap.pixelsHigh == 630)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        let copiedPreview = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: copiedPreview)
        let copiedPreviewPNG = try #require(copiedPreview.representation(using: .png, properties: [:]))
        try copiedPreviewPNG.write(
            to: outputDirectory
                .appendingPathComponent("overview-share-preview-copied\(Self.localeSuffix(language)).png"),
            options: .atomic)
        if windowCaptureEnabled {
            Self.captureWindow(
                window,
                to: outputDirectory
                    .appendingPathComponent("overview-share-window-copied\(Self.localeSuffix(language)).png"))
        }
    }

    private static func captureWindow(_ window: NSWindow, to output: URL) {
        var captured = false
        defer {
            if !captured, FileManager.default.fileExists(atPath: output.path) {
                do {
                    try FileManager.default.removeItem(at: output)
                } catch {
                    print("Overview share window capture unavailable: output cleanup failed")
                }
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            print("Overview share window capture unavailable: spawn failed")
            return
        }
        guard completed.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            _ = completed.wait(timeout: .now() + 1)
            print("Overview share window capture unavailable: timed out")
            return
        }
        guard process.terminationStatus == 0 else {
            print("Overview share window capture unavailable: exit \(process.terminationStatus)")
            return
        }
        guard let data = try? Data(contentsOf: output), data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            print("Overview share window capture unavailable: invalid PNG")
            return
        }
        captured = true
        print("Overview share window capture succeeded")
    }

    private static func localeSuffix(_ language: String) -> String {
        language == "en" ? "" : "-\(language)"
    }

    private func waitForOverviewShareInspection(
        window: NSWindow,
        outputDirectory: URL,
        language: String) throws
    {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let state = ["pid": ProcessInfo.processInfo.processIdentifier, "window": Int32(window.windowNumber)]
        try JSONEncoder().encode(state).write(
            to: outputDirectory.appendingPathComponent("state.json"),
            options: .atomic)
        let receipt = outputDirectory.appendingPathComponent("accessibility-labels.json")
        let deadline = Date().addingTimeInterval(300)
        let application = NSApplication.shared
        while !FileManager.default.fileExists(atPath: receipt.path), Date() < deadline {
            if let event = application.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            { application.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // SwiftUI's accessibility tree is lazy; inspect through the external AX client that builds it.
        let labels = try JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))
        #expect(labels.contains(L("Copy Image", language: language)))
        #expect(labels.contains(L("Copy Stats", language: language)))
    }

    @Test
    func `overview share proof paths require strict containment`() {
        #expect(self.isStrictDescendant(
            URL(fileURLWithPath: "/tmp/proof-home/output"),
            of: URL(fileURLWithPath: "/tmp/proof-home")))
        #expect(!self.isStrictDescendant(
            URL(fileURLWithPath: "/tmp/proof-home-other/output"),
            of: URL(fileURLWithPath: "/tmp/proof-home")))
        #expect(!self.isStrictDescendant(
            URL(fileURLWithPath: "/private/var/tmp/proof"),
            of: URL(fileURLWithPath: "/tmp/proof-home")))
        #expect(self.isStrictDescendant(URL(fileURLWithPath: "/tmp/proof"), of: URL(fileURLWithPath: "/")))
    }

    private func isStrictDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parentComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return childComponents.count > parentComponents.count && childComponents.starts(with: parentComponents)
    }

    @Test
    func `overview spend uses the configured dashboard bucket calendar`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 1
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let currentOffset = Calendar.current.timeZone.secondsFromGMT(for: now)
        let bucketIdentifier = currentOffset == 14 * 60 * 60
            ? "Etc/GMT+12"
            : "Pacific/Kiritimati"
        settings.costUsageBucketTimeZoneIdentifier = bucketIdentifier
        let bucketCalendar = settings.costUsageBucketCalendar
        let dayComponents = bucketCalendar.dateComponents([.year, .month, .day], from: now)
        let year = try #require(dayComponents.year)
        let month = try #require(dayComponents.month)
        let dayOfMonth = try #require(dayComponents.day)
        let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            historyDays: 1,
            costProvenance: .listPriceEstimate,
            daily: [
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: 60,
                    outputTokens: 40,
                    totalTokens: 100,
                    requestCount: 1,
                    costUSD: 1,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now), provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let model = controller.overviewSpendDashboardModel(providers: [.codex], now: now)
        let group = try #require(model.groups.first)
        let bucketStart = bucketCalendar.startOfDay(for: now)

        #expect(bucketStart != Calendar.current.startOfDay(for: now))
        #expect(group.chartDomain.lowerBound == bucketStart)
        #expect(group.timeZone.identifier == bucketCalendar.timeZone.identifier)
        #expect(group.totalCost == 1)
        #expect(group.totalTokens == 100)
        #expect(group.dailyPoints.map(\.day) == [bucketStart])
        let sharePayload = try #require(ShareStatsPayloadFactory.make(model: model, store: store))
        #expect(sharePayload.providers.map(\.provider) == [.codex])
        #expect(sharePayload.providers.first?.estimatedCost == 1)
    }

    @Test
    func `shared overview keeps Codex local ledger when global cost tracking is off`() async {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = false
        settings.codexLocalSessionCostLedgerEnabled = true
        enableTestProviders([.codex], settings: settings)
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let configuration = SpendDashboardSource.configuration(settings: settings, store: store)
        let request = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .captureOnly,
            now: now)
        let input = SpendDashboardModel.ProviderInput(
            id: "codex:local",
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: 10,
                sessionCostUSD: 4,
                last30DaysTokens: 10,
                last30DaysCostUSD: 4,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-08-17",
                        inputTokens: 5,
                        outputTokens: 5,
                        totalTokens: 10,
                        costUSD: 4,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now))
        store.spendDashboardPublication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: configuration,
            loadedAt: now,
            isRefreshing: false,
            inputs: [input],
            sources: [
                SpendSourcePublication(
                    id: input.id,
                    provider: .codex,
                    displayName: input.displayName,
                    role: .subscription,
                    state: .available),
            ])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(configuration.costUsageEnabled)
        #expect(configuration.providerIDs == [UsageProvider.codex.rawValue])
        #expect(request.configuration.costUsageEnabled)
        #expect(request.configuration.providerIDs == [UsageProvider.codex.rawValue])
        #expect(controller.overviewSpendDashboardModel(providers: [.codex], now: now).groups.first?.totalCost == 4)
    }

    @Test(arguments: ["codex", "codex:account", "claude:hidden"])
    func `initial overview waits for source filtering before sharing`(hiddenSource: String) {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        enableTestProviders([.codex], settings: settings)
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 2,
            last30DaysTokens: 10,
            last30DaysCostUSD: 2,
            daily: [.init(
                date: "2026-08-17",
                inputTokens: 5,
                outputTokens: 5,
                totalTokens: 10,
                costUSD: 2,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now), provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(store.spendDashboardPublication.configuration == nil)
        #expect(controller.overviewShareStatsPayload(now: now)?.currencies.first?.estimatedCost == 2)
        settings.spendDashboardHiddenSourceIDs = [hiddenSource]

        #expect(controller.overviewShareStatsPayload(now: now) == nil)
        let model = controller.overviewSpendDashboardModel(providers: [.codex], now: now)
        #expect(model.groups.isEmpty)
        #expect(controller.makeOverviewShareStatsMenuItem(model: model) == nil)
    }

    @Test
    func `overview consumes shared publication without starting a loader`() throws {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        let providers: [UsageProvider] = [.codex, .claude]
        enableTestProviders(Set(providers), settings: settings)
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        func input(id: String, provider: UsageProvider, cost: Double) -> SpendDashboardModel.ProviderInput {
            SpendDashboardModel.ProviderInput(
                id: id,
                provider: provider,
                displayName: id,
                snapshot: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: 10,
                    last30DaysCostUSD: cost,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: "2026-08-17",
                            inputTokens: 5,
                            outputTokens: 5,
                            totalTokens: 10,
                            costUSD: cost,
                            modelsUsed: nil,
                            modelBreakdowns: nil),
                    ],
                    updatedAt: now))
        }
        let inputs = [
            input(id: "codex:first", provider: .codex, cost: 2),
            input(id: "codex:second", provider: .codex, cost: 3),
            input(id: "claude", provider: .claude, cost: 7),
        ]
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: providers.map(\.rawValue),
            codexAccountIdentities: ["first|cache-a", "second|cache-b"],
            menuOwnershipFingerprint: SpendDashboardSource.currentMenuOwnershipFingerprint(
                settings: settings,
                store: store))
        store.spendDashboardPublication = SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: configuration,
            loadedAt: now,
            isRefreshing: false,
            inputs: inputs,
            sources: inputs.map {
                SpendSourcePublication(
                    id: $0.id,
                    provider: $0.provider,
                    displayName: $0.displayName,
                    role: .subscription,
                    state: .available)
            })
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(store.sharedSpendDashboardControllerStorage == nil)
        let model = controller.overviewSpendDashboardModel(providers: providers, now: now)
        #expect(store.sharedSpendDashboardControllerStorage == nil)
        #expect(Set(model.groups.flatMap(\.providers).map(\.id)) == ["codex:first", "codex:second", "claude"])
        #expect(model.groups.first?.totalCost == 12)
        #expect(controller.overviewSpendSubscriptionCount(providers: providers) == 3)

        settings.spendDashboardHiddenSourceIDs = ["codex:second"]
        let sharePayload = try #require(controller.overviewShareStatsPayload(now: now))
        #expect(Set(sharePayload.providers.map(\.providerName)) == ["codex:first", "claude"])
        #expect(sharePayload.currencies.first?.estimatedCost == 9)

        guard let claudeMetadata = ProviderRegistry.shared.metadata[.claude] else {
            Issue.record("Claude metadata missing")
            return
        }
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: false)
        let staleOwnerModel = controller.overviewSpendDashboardModel(providers: providers, now: now)
        #expect(staleOwnerModel.groups.isEmpty)
    }

    @Test
    func `overview fallback excludes pi local history from subscription count`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        #expect(store.spendDashboardPublication.configuration == nil)
        #expect(controller.overviewSpendSubscriptionCount(providers: [.claude, .pi]) == 1)
    }

    @Test
    func `overview accounts for all six selected providers while summing only available spend`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        let selected: [UsageProvider] = [.openai, .claude, .gemini, .antigravity, .openrouter, .grok]
        settings.mergedOverviewSelectedProviders = selected
        enableTestProviders(Set(selected), settings: settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        func snapshot(cost: Double) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: cost,
                costProvenance: .vendorMetered,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-08-17",
                        inputTokens: 0,
                        outputTokens: 0,
                        totalTokens: 0,
                        requestCount: 1,
                        costUSD: cost,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now)
        }
        store._setTokenSnapshotForTesting(snapshot(cost: 35.09), provider: .claude)
        store._setTokenSnapshotForTesting(snapshot(cost: 39.79), provider: .openrouter)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let overviewProviders = settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: selected)
        let model = controller.overviewSpendDashboardModel(providers: overviewProviders, now: now)
        let summary = OverviewSpendSummary(model: model, providerCount: overviewProviders.count)

        #expect(overviewProviders == selected)
        #expect(model.groups.first?.providers.map(\.provider).sorted { $0.rawValue < $1.rawValue } == [
            .claude,
            .openrouter,
        ])
        #expect(abs((model.groups.first?.totalCost ?? -1) - 74.88) < 1e-9)
        #expect(summary.providerCoverageText == "2 of 6 subscriptions have spend")
        #expect(summary.isPartial)
    }

    @Test
    func `overview keeps six visible providers while accounting for all seven connected providers`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        let connected: [UsageProvider] = [
            .openai,
            .claude,
            .gemini,
            .antigravity,
            .openrouter,
            .grok,
            .codex,
        ]
        enableTestProviders(Set(connected), settings: settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let enabledRoster = store.enabledFirstPartyProvidersForDisplay()
        #expect(Set(enabledRoster) == Set(connected))
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let year = try #require(components.year)
        let month = try #require(components.month)
        let dayOfMonth = try #require(components.day)
        let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        for provider in enabledRoster {
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: now),
                provider: provider)
        }
        func snapshot(cost: Double) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: cost,
                costProvenance: .vendorMetered,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: day,
                        inputTokens: 0,
                        outputTokens: 0,
                        totalTokens: 0,
                        requestCount: 1,
                        costUSD: cost,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now)
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let scopes = controller.overviewProviderScopes(enabledProviders: enabledRoster)
        let hiddenProvider = try #require(scopes.spend.first { !scopes.visible.contains($0) })
        let pricedProviders = [scopes.visible[0], scopes.visible[1], hiddenProvider]
        store._setTokenSnapshotForTesting(snapshot(cost: 35.09), provider: pricedProviders[0])
        store._setTokenSnapshotForTesting(snapshot(cost: 39.79), provider: pricedProviders[1])
        store._setTokenSnapshotForTesting(snapshot(cost: 10.12), provider: pricedProviders[2])
        store._setTokenSnapshotForTesting(snapshot(cost: 1000), provider: .cursor)

        let duplicateScopes = controller.overviewProviderScopes(
            enabledProviders: enabledRoster + [enabledRoster[0]])
        let model = controller.overviewSpendDashboardModel(providers: scopes.spend, now: now)
        let summary = OverviewSpendSummary(model: model, providerCount: scopes.spend.count)
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let ids = menu.items.compactMap { $0.representedObject as? String }
        let overviewRows = ids.filter { $0.hasPrefix("overviewRow-") }

        #expect(scopes.visible.count == 6)
        #expect(!scopes.visible.contains(hiddenProvider))
        #expect(scopes.spend == enabledRoster)
        #expect(duplicateScopes.spend == enabledRoster)
        #expect(Set(overviewRows) == Set(scopes.visible.map { "overviewRow-\($0.rawValue)" }))
        #expect(overviewRows.count == 6)
        #expect(ids.contains("overviewSpendSummary"))
        #expect(ids.contains("overviewShareStats"))
        let shareItem = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewShareStats"
        })
        #expect(shareItem.title == "Share Usage Snapshot…")
        #expect(shareItem.image != nil)
        #expect(shareItem.action == #selector(StatusItemController.presentOverviewShareStats))
        #expect(Set(model.groups.first?.providers.map(\.provider) ?? []) == Set(pricedProviders))
        #expect(abs((model.groups.first?.totalCost ?? -1) - 85) < 1e-9)
        #expect(summary.primarySpendText == "~$85.00")
        #expect(summary.providerCoverageText == "3 of 7 subscriptions have spend")
        #expect(summary.isPartial)
    }

    @Test
    func `overview spend follows the inline display preference`() throws {
        for (style, enabled) in [
            (CostSummaryDisplayStyle.inlineSummary, true),
            (.both, true),
            (.costSubmenu, false),
        ] {
            let result = try self.overviewSpendSummaryIsPresent(style: style, costUsageEnabled: true)
            #expect(result == enabled, "Unexpected Overview spend visibility for \(style.rawValue)")
        }

        #expect(try !self.overviewSpendSummaryIsPresent(style: .both, costUsageEnabled: false))
    }

    private func overviewSpendSummaryIsPresent(
        style: CostSummaryDisplayStyle,
        costUsageEnabled: Bool) throws -> Bool
    {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costSummaryDisplayStyle = style
        settings.costUsageEnabled = costUsageEnabled

        enableTestProviders([.codex, .claude], settings: settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let year = try #require(components.year)
        let month = try #require(components.month)
        let dayOfMonth = try #require(components.day)
        let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            costProvenance: .listPriceEstimate,
            daily: [
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: 60,
                    outputTokens: 40,
                    totalTokens: 100,
                    requestCount: 1,
                    costUSD: 1,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now), provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let hasSpendSummary = menu.items.contains {
            ($0.representedObject as? String) == "overviewSpendSummary"
        }
        let hasShareAction = menu.items.contains {
            ($0.representedObject as? String) == "overviewShareStats"
        }
        #expect(hasShareAction == hasSpendSummary)
        return hasSpendSummary
    }
}
