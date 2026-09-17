#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// Enters before normal app construction. The supplied directory contains only synthetic test data.
@MainActor
enum CodexRemoteCostNativeProof {
    enum LaunchDisposition: Equatable {
        case normalApplication
        case rejectedProof
        case proof(root: String)
    }

    /// Proof-only task bundles must never fall through to normal startup when a launcher drops arguments or env.
    static func launchDisposition(
        arguments: [String],
        proofOnlyBundle: Bool,
        root: String?,
        configuredHome: String?,
        homeDirectory: String) -> LaunchDisposition
    {
        guard proofOnlyBundle || arguments.contains("--codex-remote-cost-proof") else { return .normalApplication }
        guard let root, root.hasPrefix("/"), configuredHome == root + "/home",
              homeDirectory == root + "/home"
        else { return .rejectedProof }
        return .proof(root: root)
    }

    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let disposition = self.launchDisposition(
            arguments: CommandLine.arguments,
            proofOnlyBundle: Bundle.main.object(forInfoDictionaryKey: "CodexSyntheticProofOnly") as? Bool == true,
            root: environment["CODEXBAR_REMOTE_COST_PROOF_ROOT"],
            configuredHome: environment["CFFIXED_USER_HOME"],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        let path: String
        switch disposition {
        case .normalApplication:
            return false
        case .rejectedProof:
            fputs("Proof requires an absolute fixture root and CFFIXED_USER_HOME=<root>/home.\n", stderr)
            return true
        case let .proof(root):
            path = root
        }
        CodexBarLocalizationOverride.setPersistentProofLanguage("en")
        configureUsageFormatterLocalizationProvider()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(
            root: URL(fileURLWithPath: path),
            environment: environment)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
        let root: URL
        let environment: [String: String]
        var window: NSWindow?
        var store: UsageStore?
        var timer: Timer?
        let requests = RequestCounter()
        var baselineState = "loading"

        init(
            root: URL,
            environment: [String: String])
        {
            self.root = root
            self.environment = environment
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            do {
                for name in ["home", "local-codex", "pricing", "local-cache", "temporary", "output"] {
                    try FileManager.default.createDirectory(
                        at: self.root.appendingPathComponent(name),
                        withIntermediateDirectories: true)
                }
                let defaults = RemoteCostProofDefaults(values: [
                    "tokenCostUsageEnabled": true,
                    "codexLocalSessionCostLedgerEnabled": true,
                    "tokenCostUsageHistoryDays": 7,
                    "tokenCostUsageBucketTimeZone": self.environment["CODEXBAR_REMOTE_COST_PROOF_TIMEZONE"] ?? "UTC",
                    "debugDisableKeychainAccess": true,
                    "codexRemoteCostHost": self.environment["CODEXBAR_REMOTE_COST_PROOF_HOST"] ?? "",
                    "codexRemoteCostHome": self.environment["CODEXBAR_REMOTE_COST_PROOF_REMOTE_HOME"] ?? "~/.codex",
                ])
                let configStore = CodexBarConfigStore(fileURL: self.root.appendingPathComponent("config.json"))
                try configStore.save(CodexBarConfig(providers: UsageProvider.allCases.map {
                    ProviderConfig(
                        id: $0.instanceID,
                        enabled: $0 == .codex)
                }))
                let settings = SettingsStore(
                    userDefaults: defaults,
                    configStore: configStore,
                    keychainAccessPolicy: .init(
                        setDisabled: { _ in },
                        isExplicitlyDisabled: { true }),
                    performInitialProviderDetection: false,
                    isolatedStartup: true)
                settings.costSummaryDisplayStyle = .both
                var environment = self.environment
                environment["HOME"] = self.root.appendingPathComponent("home").path
                environment["CODEX_HOME"] = self.root.appendingPathComponent("local-codex").path
                let temporaryRoot = self.root.appendingPathComponent("temporary")
                let remoteFetcher = CodexCombinedCostFetcher(
                    environment: environment,
                    temporaryRoot: temporaryRoot)
                let mirror = CodexRemoteLogMirror(
                    environment: environment,
                    temporaryRoot: temporaryRoot)
                let requests = self.requests
                let remote = CodexRemoteCostStore(
                    defaults: defaults,
                    loader: { request, progress in
                        requests.increment()
                        return try await remoteFetcher.load(
                            request,
                            progress: progress)
                    },
                    cleanup: { try await mirror.cleanupAbandonedRequests() })
                let localCache = self.root.appendingPathComponent("local-cache")
                let fetcher = CostUsageFetcher(
                    cacheRoot: localCache,
                    calendar: settings.costUsageBucketCalendar)
                let store = UsageStore(
                    fetcher: UsageFetcher(environment: environment),
                    browserDetection: BrowserDetection(
                        homeDirectory: self.root.appendingPathComponent("home").path,
                        cacheTTL: 0),
                    costUsageFetcher: fetcher,
                    codexRemoteCostStore: remote,
                    codexRemotePricingCacheRoot: self.root.appendingPathComponent("pricing"),
                    codexRemoteLocalCostCacheRoot: localCache,
                    accountInfoOverride: AccountInfo(
                        email: nil,
                        plan: nil),
                    settings: settings,
                    historicalUsageHistoryStore: HistoricalUsageHistoryStore(
                        fileURL: self.root.appendingPathComponent("output/local-history.jsonl")),
                    planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
                    startupBehavior: .testing,
                    environmentBase: environment,
                    pluginApprovalStore: ProviderPluginApprovalStore(
                        fileURL: self.root.appendingPathComponent("output/plugin-approvals.json")),
                    widgetSnapshotURL: self.root.appendingPathComponent("output/widget.json"),
                    widgetTimelineReloader: {})
                self.store = store
                let window = NSWindow(
                    contentRect: NSRect(
                        x: 0,
                        y: 0,
                        width: 1060,
                        height: 820),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false)
                window.title = "CodexBar — Synthetic manual SSH proof"
                window.isReleasedWhenClosed = false
                window.isRestorable = false
                window.delegate = self
                window.contentView = NSHostingView(rootView: ProofView(store: store))
                self.window = window
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                let timer = Timer(
                    timeInterval: 0.25,
                    repeats: true)
                { [weak self] _ in
                    MainActor.assumeIsolated { self?.writeReceipt() }
                }
                self.timer = timer
                RunLoop.main.add(
                    timer,
                    forMode: .common)
                Task { @MainActor [weak self] in
                    await store.codexRemoteCosts.retryCleanup()
                    do {
                        let snapshot = try await fetcher.loadTokenSnapshot(
                            provider: .codex,
                            environment: environment,
                            forceRefresh: true,
                            codexHomePath: environment["CODEX_HOME"],
                            historyDays: 7,
                            allowPricingRefresh: false,
                            refreshPricingInBackground: false,
                            includePiSessions: false)
                        store.installCachedTokenSnapshot(
                            snapshot,
                            for: .codex)
                        self?.baselineState = "ready"
                    } catch {
                        self?.baselineState = "failed"
                    }
                    self?.writeReceipt()
                }
            } catch {
                fputs("Could not initialize isolated proof files.\n", stderr)
                NSApplication.shared.terminate(nil)
            }
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            guard let store else { return .terminateNow }
            Task { @MainActor in
                await store.codexRemoteCosts.shutdown()
                self.writeReceipt()
                sender.reply(toApplicationShouldTerminate: !store.codexRemoteCosts.cleanupRequired)
            }
            return .terminateLater
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApplication.shared.terminate(nil)
            return false
        }

        private func writeReceipt() {
            guard let store else { return }
            let snapshot = store.codexCostPresentationSnapshot()
            let presentation = store.codexRemoteCostPresentation()
            let receipt: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "gitCommit": Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "unknown",
                "baseline": self.baselineState,
                "requests": self.requests.value,
                "enabled": store.codexRemoteCosts.enabled,
                "consent": store.codexRemoteCosts.consentGranted,
                "running": store.codexRemoteCosts.isRunning,
                "combined": presentation?.isCombined ?? false,
                "cleanupRequired": store.codexRemoteCosts.cleanupRequired,
                "error": store.codexRemoteCosts.errorMessage ?? "",
                "todayTokens": snapshot?.sessionTokens as Any? ?? NSNull(),
                "todayCost": snapshot?.sessionCostUSD as Any? ?? NSNull(),
                "windowTokens": snapshot?.last30DaysTokens as Any? ?? NSNull(),
                "windowCost": snapshot?.last30DaysCostUSD as Any? ?? NSNull(),
                "days": snapshot?.daily.map { [
                    "date": $0.date,
                    "tokens": $0.totalTokens as Any? ?? NSNull(),
                    "cost": $0.costUSD as Any? ?? NSNull(),
                ] } ?? [],
                "projects": snapshot?.projects.count ?? 0,
                "sessions": snapshot?.sessions.count ?? 0,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: receipt,
                options: [.sortedKeys])
            {
                try? data.write(
                    to: self.root.appendingPathComponent("output/state.json"),
                    options: .atomic)
            }
        }
    }

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            self.lock.withLock { self.count }
        }

        func increment() { self.lock.withLock { self.count += 1 } }
    }

    @MainActor
    private struct ProofView: View {
        @Bindable var store: UsageStore
        @State private var showsHistory = false

        var body: some View {
            @Bindable var settings = self.store.settings
            HStack(
                alignment: .top,
                spacing: 24)
            {
                Form {
                    CodexRemoteCostSettingsView(store: self.store)
                    Section("Presentation") {
                        Toggle(
                            "Hide Personal Info",
                            isOn: $settings.hidePersonalInfo)
                        Stepper(
                            "History: \(self.store.settings.costUsageHistoryDays) days",
                            value: $settings.costUsageHistoryDays,
                            in: 1...365)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 500)
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: 12)
                    {
                        Text("Production Codex cost card").font(.headline)
                        UsageMenuCardView(
                            model: self.store.menuCardModel(for: .codex),
                            width: 440)
                        Button("Open daily cost history") { self.showsHistory.toggle() }
                            .disabled(self.store.codexCostPresentationSnapshot()?.daily.isEmpty != false)
                            .accessibilityIdentifier("codex-remote-history")
                        if self.showsHistory, let snapshot = self.store.codexCostPresentationSnapshot() {
                            CostHistoryChartMenuView(
                                provider: .codex,
                                daily: snapshot.daily,
                                totalCostUSD: snapshot.last30DaysCostUSD,
                                historyDays: snapshot.historyDays,
                                historyCoverageIsEstablished: snapshot.historyCoverageIsEstablished,
                                windowLabel: snapshot.historyLabel,
                                scopePresentation: self.store.codexRemoteCostPresentation(),
                                projects: snapshot.projects,
                                sessions: snapshot.sessions,
                                hidePersonalInfo: self.store.settings.hidePersonalInfo,
                                width: 440)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
#endif
