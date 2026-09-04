import AppKit
import CodexBarCore
import Darwin
import Foundation

/// Opt-in, self-contained runtime proof for the packaged Usage & Spend preferences pane.
///
/// The mode is inert unless `CODEXBAR_SPEND_BUNDLE_PROOF_DIR` is present. The caller must also
/// provide isolated defaults, home, Codex, and session paths. In proof mode CodexBar disables
/// Keychain access and background work, installs synthetic spend history, opens the production
/// settings window, and records a live receipt for an external UI driver.
@MainActor
enum UsageSpendBundleProof {
    private nonisolated static let directoryKey = "CODEXBAR_SPEND_BUNDLE_PROOF_DIR"
    private static let captureInterval: TimeInterval = 0.5
    private static var controller: SpendDashboardController?
    private static var timer: Timer?

    static var isRequested: Bool {
        self.requestDirectory(environment: ProcessInfo.processInfo.environment) != nil
    }

    nonisolated static func requestDirectory(environment: [String: String]) -> String? {
        guard let path = environment[self.directoryKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    nonisolated static func isolationFailure(environment: [String: String]) -> String? {
        let requiredKeys = [
            self.directoryKey,
            "CFFIXED_USER_HOME",
            "HOME",
            "CODEX_HOME",
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS",
            CodexCredentialFileAccess.isolationEnvironmentKey,
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION",
            "SWIFT_TESTING",
            "SWIFT_TESTING_ENABLED",
        ]
        let missing = requiredKeys.filter { environment[$0]?.isEmpty != false }
        guard missing.isEmpty else {
            return "missing \(missing.sorted().joined(separator: ", "))"
        }
        let requiredOneValues = [
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS",
            CodexCredentialFileAccess.isolationEnvironmentKey,
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION",
        ]
        let invalid = requiredOneValues.filter { environment[$0] != "1" }
        guard invalid.isEmpty else {
            return "expected 1 for \(invalid.sorted().joined(separator: ", "))"
        }

        guard let requestedDirectory = self.requestDirectory(environment: environment),
              let proofRoot = self.canonicalAbsolutePath(requestedDirectory)
        else {
            return "proof root must be an absolute path"
        }
        guard let temporaryRoot = self.trustedSystemTemporaryDirectory() else {
            return "system temporary directory is unavailable"
        }
        guard self.isStrictDescendant(proofRoot, of: temporaryRoot) else {
            return "proof root must be inside the system temporary directory"
        }

        let profileKeys = ["CFFIXED_USER_HOME", "HOME", "CODEX_HOME"]
        var profilePaths: [String: String] = [:]
        for key in profileKeys {
            guard let rawPath = environment[key], let path = self.canonicalAbsolutePath(rawPath) else {
                return "\(key) must be an absolute path"
            }
            guard self.isStrictDescendant(path, of: proofRoot) else {
                return "\(key) must be inside the proof root"
            }
            profilePaths[key] = path
        }
        guard profilePaths["CFFIXED_USER_HOME"] == profilePaths["HOME"] else {
            return "CFFIXED_USER_HOME and HOME must resolve to the same directory"
        }
        return nil
    }

    /// Resolves the OS-owned per-user temporary directory without consulting `TMPDIR`.
    /// Proof mode writes defaults after this boundary passes, so an environment-controlled root is unsafe.
    nonisolated static func trustedSystemTemporaryDirectory() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            confstr(_CS_DARWIN_USER_TEMP_DIR, pointer.baseAddress, length)
        }
        guard written > 0, let terminator = buffer.firstIndex(of: 0) else { return nil }
        guard let path = String(
            bytes: buffer[..<terminator].map { UInt8(bitPattern: $0) },
            encoding: .utf8)
        else { return nil }
        return self.canonicalAbsolutePath(path)
    }

    private nonisolated static func canonicalAbsolutePath(_ rawPath: String) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private nonisolated static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        guard path != root else { return false }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(rootPrefix)
    }

    static func prepareProcessIsolation() {
        guard self.isRequested else { return }
        let environment = ProcessInfo.processInfo.environment
        if let failure = self.isolationFailure(environment: environment) {
            fputs("Usage & Spend bundle proof refused unsafe environment: \(failure)\n", stderr)
            exit(64)
        }
        KeychainAccessGate.isDisabled = true
        UserDefaults.standard.set(true, forKey: "debugDisableKeychainAccess")
        UserDefaults.standard.set(false, forKey: "openAIWebAccessEnabled")
        UserDefaults.standard.set(false, forKey: "statusChecksEnabled")
        UserDefaults.standard.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
        UserDefaults.standard.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
        UserDefaults.standard.set(true, forKey: "providerDetectionCompleted")
    }

    static func armIfRequested(
        settings: SettingsStore,
        store: UsageStore,
        selection: PreferencesSelection)
    {
        guard self.isRequested else { return }
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.preferredCurrencyCode = "USD"
        settings.costUsageBucketTimeZoneIdentifier = "UTC"

        var config = settings.configSnapshot
        // Provider-specific by design: the isolated proof pairs metered totals with local drill-down data.
        for provider in UsageProvider.allCases {
            if let index = config.providers.firstIndex(where: { $0.id == provider.instanceID }) {
                config.providers[index].enabled = provider == .cursor || provider == .opencode
            } else {
                config.providers.append(ProviderConfig(
                    id: provider.instanceID,
                    enabled: provider == .cursor || provider == .opencode))
            }
        }
        settings.updateProviderState(config: config)
        selection.pane = .usageSpend

        let now = Date()
        let configuration = SpendDashboardSource.configuration(settings: settings, store: store)
        let inputs = self.syntheticInputs(now: now, calendar: configuration.bucketCalendar)
        let proofController = SpendDashboardController(
            userDefaults: settings.userDefaults,
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
        proofController.selectDays(7)
        proofController.update(configuration: configuration)
        proofController.selectDay(now)
        store.sharedSpendDashboardControllerStorage = proofController
        self.controller = proofController
    }

    @discardableResult
    static func startIfRequested(
        openSettings: @escaping @MainActor () -> Void,
        windowProvider: @escaping @MainActor () -> NSWindow?) -> Bool
    {
        guard self.isRequested, let controller = self.controller else { return false }
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            let modelDeadline = Date().addingTimeInterval(20)
            while controller.isRefreshing || controller.model.groups.isEmpty, Date() < modelDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !controller.isRefreshing, !controller.model.groups.isEmpty else {
                self.writeFailure("Synthetic dashboard did not finish loading.")
                NSApp.terminate(nil)
                return
            }
            openSettings()
            let windowDeadline = Date().addingTimeInterval(20)
            while windowProvider()?.isVisible != true, Date() < windowDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let window = windowProvider(), window.isVisible else {
                self.writeFailure("Production settings window did not become visible.")
                NSApp.terminate(nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self.writeReceipt(window: window, controller: controller)
            let timer = Timer(timeInterval: self.captureInterval, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let window = windowProvider(), window.isVisible else { return }
                    self.writeReceipt(window: window, controller: controller)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return true
    }

    private static func writeReceipt(window: NSWindow, controller: SpendDashboardController) {
        guard let directory = self.directoryURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receipt: [String: String] = [
            "bundlePath": Bundle.main.bundleURL.path,
            "executablePath": Bundle.main.executableURL?.path ?? "unavailable",
            "bundleVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "gitCommit": Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "unknown",
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "window": String(window.windowNumber),
            "selectedDays": String(controller.selectedDays),
            "selectedDay": controller.selectedDay == nil ? "none" : "set",
            "groups": String(controller.model.groups.count),
            "dataSource": "synthetic-isolated",
            "keychain": KeychainAccessGate.isDisabled ? "disabled" : "enabled",
            "backgroundWork": "disabled",
        ]
        if let data = try? JSONEncoder().encode(receipt) {
            try? data.write(to: directory.appendingPathComponent("bundle-native-live.json"), options: .atomic)
        }
    }

    private static func writeFailure(_ message: String) {
        guard let directory = self.directoryURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? message.write(
            to: directory.appendingPathComponent("bundle-native-failure.txt"),
            atomically: true,
            encoding: .utf8)
    }

    private static var directoryURL: URL? {
        guard let path = self.requestDirectory(environment: ProcessInfo.processInfo.environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
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
        // Provider-specific by design: these synthetic fixtures cover metered and local detail capabilities.
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
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
        return CostUsageDailyReport.Entry(
            date: dayKey,
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
