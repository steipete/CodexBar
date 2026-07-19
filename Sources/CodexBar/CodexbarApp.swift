import AppKit
import CodexBarCore
import KeyboardShortcuts
import Observation
import QuartzCore
import Security
import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var store: UsageStore
    @State private var managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    @State private var codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    private let preferencesSelection: PreferencesSelection
    private let account: AccountInfo

    init() {
        let env = ProcessInfo.processInfo.environment
        let storedLevel = CodexBarLog.parseLevel(UserDefaults.standard.string(forKey: "debugLogLevel")) ?? .verbose
        let level = CodexBarLog.parseLevel(env["CODEXBAR_LOG_LEVEL"]) ?? storedLevel
        CodexBarLog.bootstrapIfNeeded(.init(
            destination: .oslog(subsystem: "com.steipete.codexbar"),
            level: level,
            json: false))

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let gitCommit = Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "unknown"
        let buildTimestamp = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String ?? "unknown"
        CodexBarLog.logger(LogCategories.app).info(
            "CodexBar starting",
            metadata: [
                "version": version,
                "build": build,
                "git": gitCommit,
                "built": buildTimestamp,
            ])

        KeychainAccessGate.isDisabled = UserDefaults.standard.bool(forKey: "debugDisableKeychainAccess")
        KeychainPromptCoordinator.install()
        if MainThreadHangWatchdog.isEnabledForCurrentProcess {
            MainThreadHangWatchdog.shared.start()
        }

        let preferencesSelection = PreferencesSelection()
        let settings = SettingsStore()
        Self.applyLanguagePreference(from: settings)
        configureUsageFormatterLocalizationProvider()
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()
        managedCodexAccountCoordinator.onManagedAccountsDidChange = {
            _ = settings.refreshCodexAccountReconciliationAfterManagedAccountsDidChange()
        }
        _ = settings.persistResolvedCodexActiveSourceCorrectionIfNeeded()
        let fetcher = UsageFetcher()
        let browserDetection = BrowserDetection(cacheTTL: BrowserDetection.defaultCacheTTL)
        let account = fetcher.loadAccountInfo()
        let store = UsageStore(fetcher: fetcher, browserDetection: browserDetection, settings: settings)
        let codexAccountPromotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)
        self.preferencesSelection = preferencesSelection
        _settings = State(wrappedValue: settings)
        _store = State(wrappedValue: store)
        _managedCodexAccountCoordinator = State(wrappedValue: managedCodexAccountCoordinator)
        _codexAccountPromotionCoordinator = State(wrappedValue: codexAccountPromotionCoordinator)
        self.account = account
        CodexBarLog.setLogLevel(settings.debugLogLevel)
        self.appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: account,
            selection: preferencesSelection,
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: codexAccountPromotionCoordinator))
    }

    @SceneBuilder
    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CodexBarLifecycleKeepalive") {
            HiddenWindowView()
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        Settings {
            PreferencesView(
                settings: self.settings,
                store: self.store,
                updater: self.appDelegate.updaterController,
                selection: self.preferencesSelection,
                managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                runProviderLoginFlow: { provider in
                    await self.appDelegate.runProviderLoginFlow(provider)
                })
        }
        .defaultSize(width: SettingsPane.windowWidth, height: SettingsPane.windowHeight)
        .windowResizability(.contentMinSize)
    }

    private func openSettings(pane: SettingsPane) {
        self.preferencesSelection.pane = pane
        NSApp.activate(ignoringOtherApps: true)
        let outcome = SettingsWindowOpener.live().open(preferred: .appKit)
        let logger = CodexBarLog.logger(LogCategories.app)
        switch outcome {
        case .preferred:
            break
        case .fallback:
            logger.warning("Settings AppKit action was not handled; used notification fallback")
        case .failed:
            logger.error("Failed to open Settings; AppKit action and notification fallback unavailable")
        }
    }

    private static func applyLanguagePreference(from settings: SettingsStore) {
        AppLanguagePreferenceMigration.clearLegacyOverrideIfOwned(storedAppLanguage: settings.appLanguage)
        resetCodexBarLocalizationCache()
    }
}

// MARK: - Updater abstraction

@MainActor
protocol UpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    var updateStatus: UpdateStatus { get }
    func checkForUpdates(_ sender: Any?)
    func installUpdate()
}

/// No-op updater used for debug builds and non-bundled runs to suppress Sparkle dialogs.
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool = false
    var automaticallyDownloadsUpdates: Bool = false
    let isAvailable: Bool = false
    let unavailableReason: String?
    let updateStatus = UpdateStatus()

    init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }

    func checkForUpdates(_ sender: Any?) {}
    func installUpdate() {}
}

@MainActor
@Observable
final class UpdateStatus {
    static let disabled = UpdateStatus()
    var isUpdateReady: Bool

    init(isUpdateReady: Bool = false) {
        self.isUpdateReady = isUpdateReady
    }
}

#if canImport(Sparkle) && ENABLE_SPARKLE
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, SPUUpdaterDelegate {
    private final class ImmediateInstallHandler: @unchecked Sendable {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        func install() {
            self.handler()
        }
    }

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil)
    let updateStatus = UpdateStatus()
    let unavailableReason: String? = nil
    private var immediateInstallHandler: ImmediateInstallHandler?

    init(savedAutoUpdate: Bool) {
        super.init()
        let updater = self.controller.updater
        updater.automaticallyChecksForUpdates = savedAutoUpdate
        updater.automaticallyDownloadsUpdates = savedAutoUpdate
        self.controller.startUpdater()
    }

    var automaticallyChecksForUpdates: Bool {
        get { self.controller.updater.automaticallyChecksForUpdates }
        set { self.controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { self.controller.updater.automaticallyDownloadsUpdates }
        set { self.controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var isAvailable: Bool {
        true
    }

    func checkForUpdates(_ sender: Any?) {
        self.controller.checkForUpdates(sender)
    }

    func installUpdate() {
        guard let immediateInstallHandler else {
            self.controller.checkForUpdates(nil)
            return
        }

        immediateInstallHandler.install()
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        _ = updater
        _ = item
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        _ = updater
        _ = item
        _ = error
        Task { @MainActor in
            self.immediateInstallHandler = nil
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func userDidCancelDownload(_ updater: SPUUpdater) {
        _ = updater
        Task { @MainActor in
            self.immediateInstallHandler = nil
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void)
        -> Bool
    {
        _ = updater
        _ = item
        let installHandler = ImmediateInstallHandler(immediateInstallHandler)
        Task { @MainActor in
            self.immediateInstallHandler = installHandler
            self.updateStatus.isUpdateReady = true
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        _ = updater
        _ = error
        Task { @MainActor in
            self.immediateInstallHandler = nil
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState)
    {
        let downloaded = state.stage == .downloaded
        Task { @MainActor in
            switch choice {
            case .install, .skip:
                self.immediateInstallHandler = nil
                self.updateStatus.isUpdateReady = false
            case .dismiss:
                self.updateStatus.isUpdateReady = downloaded
            @unknown default:
                self.immediateInstallHandler = nil
                self.updateStatus.isUpdateReady = false
            }
        }
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.current.allowedSparkleChannels
    }
}

private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else { return false }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return false }

    if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
        return summary.hasPrefix("Developer ID Application:")
    }
    return false
}

@MainActor
private func makeUpdaterController() -> UpdaterProviding {
    let bundleURL = Bundle.main.bundleURL
    let isBundledApp = bundleURL.pathExtension == "app"
    guard isBundledApp else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    if InstallOrigin.isHomebrewCask(appBundleURL: bundleURL) {
        return DisabledUpdaterController(
            unavailableReason: "Updates managed by Homebrew. Run: brew upgrade --cask steipete/tap/codexbar")
    }

    guard isDeveloperIDSigned(bundleURL: bundleURL) else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    let defaults = UserDefaults.standard
    let autoUpdateKey = "autoUpdateEnabled"
    // Default to true for first launch; fall back to saved preference thereafter.
    let savedAutoUpdate = (defaults.object(forKey: autoUpdateKey) as? Bool) ?? true
    return SparkleUpdaterController(savedAutoUpdate: savedAutoUpdate)
}
#else
private func makeUpdaterController() -> UpdaterProviding {
    DisabledUpdaterController()
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct Dependencies {
        let store: UsageStore
        let settings: SettingsStore
        let account: AccountInfo
        let selection: PreferencesSelection
        let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
        let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    }

    let updaterController: UpdaterProviding = makeUpdaterController()
    private let confettiOverlayController = ScreenConfettiOverlayController()
    private let confettiLogger = CodexBarLog.logger(LogCategories.confetti)
    private lazy var memoryPressureMonitor = MemoryPressureMonitor(trimAppCaches: { [weak self] in
        self?.trimRebuildableCachesForMemoryPressure() ?? MemoryPressureCacheTrimSummary()
    })

    private var statusController: StatusItemControlling?
    private var store: UsageStore?
    private var settings: SettingsStore?
    private var account: AccountInfo?
    private var preferencesSelection: PreferencesSelection?
    private var managedCodexAccountCoordinator: ManagedCodexAccountCoordinator?
    private var codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator?
    private var hasInstalledLimitResetObservers = false
    #if DEBUG
    private var debugMemoryPressureObserver: NSObjectProtocol?
    #endif
    var terminateActiveProcessesForAppShutdown: () -> Void = {
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
    }

    func configure(_ dependencies: Dependencies) {
        self.store = dependencies.store
        self.settings = dependencies.settings
        self.account = dependencies.account
        self.preferencesSelection = dependencies.selection
        self.managedCodexAccountCoordinator = dependencies.managedCodexAccountCoordinator
        self.codexAccountPromotionCoordinator = dependencies.codexAccountPromotionCoordinator
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        self.configureAppIconForMacOSVersion()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.memoryPressureMonitor.start()
        #if DEBUG
        self.installDebugMemoryPressureObserverIfNeeded()
        #endif
        self.ensureStatusController()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let settings = self?.settings else { return }
            AdaptiveActivityConsentPresenter.presentIfNeeded(settings: settings)
            AppNotifications.shared.requestAuthorizationOnStartup()
        }
        KeyboardShortcuts.onKeyUp(for: .openMenu) { [weak self] in
            // KeyboardShortcuts dispatches both normal and menu-tracking hotkeys on the main event loop.
            MainActor.assumeIsolated {
                self?.statusController?.openMenuFromShortcut()
            }
        }
        if !self.hasInstalledLimitResetObservers {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleSessionLimitResetNotification(_:)),
                name: .codexbarSessionLimitReset,
                object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleWeeklyLimitResetNotification(_:)),
                name: .codexbarWeeklyLimitReset,
                object: nil)
            self.hasInstalledLimitResetObservers = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.memoryPressureMonitor.stop()
        #if DEBUG
        self.removeDebugMemoryPressureObserver()
        #endif
        self.statusController?.prepareForAppShutdown()
        self.confettiOverlayController.dismiss()
        self.dismissAppKitWindowsForShutdown()
        self.terminateActiveProcessesForAppShutdown()
    }

    func runProviderLoginFlow(_ provider: UsageProvider) async {
        self.ensureStatusController()
        guard let statusController else { return }
        await statusController.runLoginFlowFromSettings(provider: provider)
    }

    @objc private func handleSessionLimitResetNotification(_ notification: Notification) {
        guard let event = notification.object as? SessionLimitResetEvent else { return }
        guard self.settings?.confettiOnSessionLimitResetsEnabled == true else { return }
        self.playLimitResetConfetti(
            provider: event.provider,
            accountIdentifier: event.accountIdentifier,
            resetKind: "session")
    }

    @objc private func handleWeeklyLimitResetNotification(_ notification: Notification) {
        guard let event = notification.object as? WeeklyLimitResetEvent else { return }
        guard self.settings?.confettiOnWeeklyLimitResetsEnabled == true else { return }
        self.playLimitResetConfetti(
            provider: event.provider,
            accountIdentifier: event.accountIdentifier,
            resetKind: "weekly")
    }

    private func playLimitResetConfetti(
        provider: UsageProvider,
        accountIdentifier: String,
        resetKind: String)
    {
        let origin = self.statusController?.celebrationOriginPoint(for: provider)
        let palette = ProviderDescriptorRegistry.descriptor(for: provider).branding.confettiPalette
        self.confettiLogger.info(
            "Triggering confetti",
            metadata: [
                "provider": provider.rawValue,
                "accountIdentifier": accountIdentifier,
                "resetKind": resetKind,
                "originKnown": origin == nil ? "0" : "1",
            ])
        self.confettiOverlayController.play(originInScreen: origin, colors: palette)
    }

    /// Use the classic (non-Liquid Glass) app icon on macOS versions before 26.
    private func configureAppIconForMacOSVersion() {
        if #unavailable(macOS 26) {
            self.applyClassicAppIcon()
        }
    }

    private func applyClassicAppIcon() {
        guard let classicIcon = Self.loadClassicIcon() else { return }
        NSApp.applicationIconImage = classicIcon
    }

    private static func loadClassicIcon() -> NSImage? {
        guard let url = self.classicIconURL(),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        return image
    }

    private static func classicIconURL() -> URL? {
        Bundle.main.url(forResource: "Icon-classic", withExtension: "icns")
    }

    private func dismissAppKitWindowsForShutdown() {
        guard let app = NSApp else { return }
        for window in app.windows {
            window.orderOut(nil)
        }
    }

    private func ensureStatusController() {
        if self.statusController != nil {
            return
        }

        if let store,
           let settings,
           let account,
           let selection = self.preferencesSelection,
           let managedCodexAccountCoordinator,
           let codexAccountPromotionCoordinator
        {
            self.statusController = StatusItemController.factory(
                store,
                settings,
                account,
                self.updaterController,
                selection,
                managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator)
            return
        }

        // Defensive fallback: this should not be hit in normal app lifecycle.
        CodexBarLog.logger(LogCategories.app)
            .error("StatusItemController fallback path used; settings/store mismatch likely.")
        assertionFailure("StatusItemController fallback path used; check app lifecycle wiring.")
        let fallbackSettings = SettingsStore()
        let fetcher = UsageFetcher()
        let browserDetection = BrowserDetection(cacheTTL: BrowserDetection.defaultCacheTTL)
        let fallbackAccount = fetcher.loadAccountInfo()
        let fallbackStore = UsageStore(fetcher: fetcher, browserDetection: browserDetection, settings: fallbackSettings)
        let fallbackManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator()
        let fallbackCodexAccountPromotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: fallbackSettings,
            usageStore: fallbackStore,
            managedAccountCoordinator: fallbackManagedCodexAccountCoordinator)
        self.statusController = StatusItemController.factory(
            fallbackStore,
            fallbackSettings,
            fallbackAccount,
            self.updaterController,
            PreferencesSelection(),
            fallbackManagedCodexAccountCoordinator,
            fallbackCodexAccountPromotionCoordinator)
    }

    private func trimRebuildableCachesForMemoryPressure() -> MemoryPressureCacheTrimSummary {
        var summary = MemoryPressureCacheTrimSummary()
        let statusSummary = self.statusController?.trimRebuildableCachesForMemoryPressure()
            ?? MemoryPressureCacheTrimSummary()
        let storeSummary = self.store?.trimRebuildableCachesForMemoryPressure()
            ?? MemoryPressureCacheTrimSummary()
        summary.merge(statusSummary)
        summary.merge(storeSummary)
        return summary
    }

    #if DEBUG
    private func installDebugMemoryPressureObserverIfNeeded() {
        guard self.debugMemoryPressureObserver == nil else { return }
        self.debugMemoryPressureObserver = DistributedNotificationCenter.default().addObserver(
            forName: .codexbarDebugSimulateMemoryPressure,
            object: nil,
            queue: .main)
        { [weak self] notification in
            let rawLevel = notification.userInfo?["level"] as? String
            let shouldSeedCaches = notification.userInfo?["seedCaches"] as? String == "1"
            MainActor.assumeIsolated {
                self?.handleDebugMemoryPressureNotification(
                    rawLevel: rawLevel,
                    shouldSeedCaches: shouldSeedCaches)
            }
        }
    }

    private func removeDebugMemoryPressureObserver() {
        guard let observer = self.debugMemoryPressureObserver else { return }
        DistributedNotificationCenter.default().removeObserver(observer)
        self.debugMemoryPressureObserver = nil
    }

    private func handleDebugMemoryPressureNotification(rawLevel: String?, shouldSeedCaches: Bool) {
        let isCritical = rawLevel?.caseInsensitiveCompare("critical") == .orderedSame
        if shouldSeedCaches {
            OpenAIDashboardFetcher.seedCachedWebViewsForMemoryPressureProof()
            self.statusController?.seedRebuildableCachesForMemoryPressureProof()
            self.store?.seedRebuildableCachesForMemoryPressureProof()
        }
        CodexBarLog.logger(LogCategories.memoryPressure).info(
            "Debug memory pressure notification received",
            metadata: [
                "level": isCritical ? "critical" : "warning",
                "seedCaches": shouldSeedCaches ? "1" : "0",
            ])
        self.memoryPressureMonitor.handleMemoryPressureForTesting(isWarning: !isCritical, isCritical: isCritical)
    }
    #endif

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
