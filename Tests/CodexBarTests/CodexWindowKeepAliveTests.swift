import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CodexWindowKeepAliveTests {
    private static let resetsAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// When the boundary refresh pass started: the expired reset plus the scheduler's grace period.
    private static let refreshStartedAt = resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds)
    /// A Codex publication that happened during that pass.
    private static let freshPublicationAt = refreshStartedAt.addingTimeInterval(1)

    @Test
    func `runner sends the documented exec ping in a read-only sandbox`() {
        let arguments = CodexWindowKeepAliveRunner.arguments()

        #expect(arguments.first == "exec")
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--json"))
        #expect(arguments.last == "ping")
        let sandboxIndex = arguments.firstIndex(of: "--sandbox")
        #expect(sandboxIndex.map { arguments[$0 + 1] } == "read-only")
    }

    @Test
    func `runner fails closed when the Codex CLI cannot be resolved`() async {
        await #expect(throws: CodexWindowKeepAliveError.self) {
            try await CodexWindowKeepAliveRunner.run(
                environment: [:],
                timeout: 1,
                resolveExecutable: { _, _ in nil })
        }
    }

    @Test
    func `keep-alive runs only for the Codex session window after an expired boundary`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context()) == nil)
    }

    @Test
    @MainActor
    func `keep-alive stays off by default`() {
        let settings = testSettingsStore(suiteName: "CodexWindowKeepAliveTests-default")

        #expect(settings.codexWindowKeepAliveEnabled == false)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(enabled: settings.codexWindowKeepAliveEnabled)) == .disabled)
    }

    @Test
    @MainActor
    func `setting persists to user defaults`() throws {
        let defaults = try #require(UserDefaults(suiteName: "CodexWindowKeepAliveTests-persist-\(UUID().uuidString)"))
        let settings = testSettingsStore(suiteName: "CodexWindowKeepAliveTests-persist", userDefaults: defaults)

        settings.codexWindowKeepAliveEnabled = true

        #expect(defaults.bool(forKey: "codexWindowKeepAliveEnabled"))
        #expect(settings.codexWindowKeepAliveEnabled)
    }

    @Test
    func `keep-alive ignores other providers and weekly windows`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(window: Self.window(instanceID: .claude))) == .notCodexSessionWindow)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(window: Self.window(windowMinutes: 7 * 24 * 60))) == .notCodexSessionWindow)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(window: Self.window(windowMinutes: nil))) == .notCodexSessionWindow)
    }

    @Test
    func `keep-alive skips disabled provider low power and repeated boundaries`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(codexEnabled: false)) == .codexDisabled)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(lowPowerModeEnabled: true)) == .lowPowerMode)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(attemptedBoundaries: [Self.resetsAt])) == .alreadyAttempted)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(refreshedSnapshot: nil)) == .snapshotMissing)
    }

    @Test
    func `keep-alive stays inert under Manual refresh cadence`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(refreshCadenceIsManual: true)) == .manualRefreshCadence)
    }

    @Test
    func `keep-alive rejects a selected managed workspace the CLI cannot carry`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(selectedManagedWorkspaceID: "workspace-example")) == .managedWorkspaceUnsupported)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(selectedManagedWorkspaceID: "")) == nil)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(selectedManagedWorkspaceID: nil)) == nil)
    }

    @Test
    func `keep-alive requires a Codex snapshot published by the boundary pass`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(snapshotPublishedAt: nil)) == .snapshotStale)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(
            snapshotPublishedAt: Self.refreshStartedAt.addingTimeInterval(-1))) == .snapshotStale)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(
            snapshotPublishedAt: Self.refreshStartedAt)) == nil)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(
            snapshotPublishedAt: Self.freshPublicationAt)) == nil)
    }

    @Test
    func `keep-alive does not ping when a new window already started`() {
        let advanced = Self.snapshot(primaryResetsAt: Self.resetsAt.addingTimeInterval(5 * 60 * 60))
        let stillExpired = Self.snapshot(primaryResetsAt: Self.resetsAt.addingTimeInterval(30))
        let noReset = Self.snapshot(primaryResetsAt: nil)

        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(refreshedSnapshot: advanced)) == .newWindowAlreadyStarted)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(refreshedSnapshot: stillExpired)) == nil)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(refreshedSnapshot: noReset)) == nil)
    }

    @Test
    func `keep-alive only spends a readable ChatGPT subscription login`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(authority: nil)) == .loginUnavailable)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(authority: Self.authority(isAPIKeyLogin: true))) == .apiKeyLoginUnsupported)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(authority: Self.authority())) == nil)
    }

    @Test
    func `pending ping is dropped when consent the selected account or the same-home login changes`() {
        let captured = Self.authority()

        #expect(UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true, capturedAuthority: captured, currentAuthority: captured))
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: false, capturedAuthority: captured, currentAuthority: captured))
        // Selected account switched: different CODEX_HOME.
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true,
            capturedAuthority: captured,
            currentAuthority: Self.authority(environment: ["CODEX_HOME": "/tmp/codexbar-keepalive-tests/b"])))
        // Replacement login in the same home: same environment, different auth.json bytes.
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true,
            capturedAuthority: captured,
            currentAuthority: Self.authority(authFingerprint: "fingerprint-b")))
        // Same file bytes but a different account claim (defense in depth).
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true,
            capturedAuthority: captured,
            currentAuthority: Self.authority(accountID: "account-b")))
        // Login swapped to an API key, or signed out entirely.
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true, capturedAuthority: captured, currentAuthority: Self.authority(isAPIKeyLogin: true)))
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true, capturedAuthority: captured, currentAuthority: nil))
    }

    @Test(CodexCredentialFixtures())
    func `authority loader reads the login codex exec would spend and fails closed`() throws {
        let home = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = ["CODEX_HOME": home.path]

        #expect(UsageStore.loadCodexWindowKeepAliveAuthority(environment: env) == nil)

        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                idToken: nil,
                accountId: "account-a",
                lastRefresh: Date()),
            env: env)
        let chatGPT = try #require(UsageStore.loadCodexWindowKeepAliveAuthority(environment: env))
        #expect(chatGPT.environment == env)
        #expect(chatGPT.accountID == "account-a")
        #expect(!chatGPT.isAPIKeyLogin)
        #expect(chatGPT.authFingerprint == CodexAuthFingerprint.fingerprint(homePath: home.path))

        let apiKeyJSON = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-test-not-a-real-key"])
        try apiKeyJSON.write(to: home.appendingPathComponent("auth.json"))
        let apiKey = try #require(UsageStore.loadCodexWindowKeepAliveAuthority(environment: env))
        #expect(apiKey.isAPIKeyLogin)
        #expect(apiKey.authFingerprint != chatGPT.authFingerprint)
    }

    @Test
    @MainActor
    func `toggle explains why it is inert under Manual cadence or an added workspace`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-status")
        defer { settings._test_codexAccountSnapshotLoader = nil }

        let chatGPT = Self.authority()
        #expect(Self.statusText(settings, authority: chatGPT) == nil)

        settings.refreshFrequency = .manual
        #expect(Self.statusText(settings, authority: chatGPT)?.contains("Manual") == true)

        settings.refreshFrequency = .fiveMinutes
        Self.selectManagedWorkspace(in: settings)
        #expect(settings.codexSettingsSnapshot(tokenOverride: nil).managedWorkspaceAccountID == "workspace-example")
        #expect(Self.statusText(settings, authority: chatGPT)?.contains("workspace") == true)
    }

    @Test
    @MainActor
    func `toggle explains why it is inert for API key or missing logins`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-status-login")
        defer { settings._test_codexAccountSnapshotLoader = nil }

        #expect(Self.statusText(settings, authority: Self.authority(isAPIKeyLogin: true))?
            .contains("API key") == true)
        #expect(Self.statusText(settings, authority: nil)?.contains("signed in") == true)
    }

    @Test
    @MainActor
    func `store pings once per boundary through the injected runner`() async throws {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-store")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        let counter = PingCounter()
        store.codexWindowKeepAliveRunner = { _ in await counter.increment() }
        defer { store.cancelCodexWindowKeepAlive() }

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)
        let firstTask = try #require(store.codexWindowKeepAliveTask)
        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)

        #expect(store.codexWindowKeepAliveTask == firstTask)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries == [Self.resetsAt])
        try await Self.waitUntil { await counter.count == 1 }
        #expect(await counter.count == 1)
    }

    @Test
    @MainActor
    func `store does not ping when the pass kept a stale Codex snapshot`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-stale")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        store.lastSnapshotPublicationAt[.codex] = Self.storeRefreshStartedAt.addingTimeInterval(-60)

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)

        #expect(store.codexWindowKeepAliveTask == nil)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries.isEmpty)
    }

    @Test
    @MainActor
    func `store does not ping for a selected managed workspace`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-workspace")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        Self.selectManagedWorkspace(in: settings)
        let store = Self.makeStore(settings: settings)

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)

        #expect(store.codexWindowKeepAliveTask == nil)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries.isEmpty)
    }

    @Test
    @MainActor
    func `store does not ping for an API key login`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-apikey")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        store.codexWindowKeepAliveAuthorityLoader = { Self.authority(environment: $0, isAPIKeyLogin: true) }

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)

        #expect(store.codexWindowKeepAliveTask == nil)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries.isEmpty)
    }

    @Test
    @MainActor
    func `store drops a queued ping when the login in the same home changes before launch`() async throws {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-login-change")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        let counter = PingCounter()
        store.codexWindowKeepAliveRunner = { _ in await counter.increment() }
        defer { store.cancelCodexWindowKeepAlive() }

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)
        let task = try #require(store.codexWindowKeepAliveTask)
        // Same CODEX_HOME, different auth.json: the launch-time re-check must reject the replacement login.
        store.codexWindowKeepAliveAuthorityLoader = {
            Self.authority(environment: $0, authFingerprint: "fingerprint-b", accountID: "account-b")
        }
        await task.value

        let pinged = await counter.hasPinged
        #expect(!pinged)
    }

    @Test
    @MainActor
    func `store drops a queued ping when the toggle is turned off before launch`() async throws {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-consent")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        let counter = PingCounter()
        store.codexWindowKeepAliveRunner = { _ in await counter.increment() }
        defer { store.cancelCodexWindowKeepAlive() }

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)
        let task = try #require(store.codexWindowKeepAliveTask)
        // The detached task must hop back to the main actor before launching; flipping the toggle first wins.
        settings.codexWindowKeepAliveEnabled = false
        await task.value

        let pinged = await counter.hasPinged
        #expect(!pinged)

        store.cancelCodexWindowKeepAlive()
        #expect(store.codexWindowKeepAliveTask == nil)
    }

    // MARK: - Helpers

    /// A boundary pass that started well before `makeStore` records its Codex publication at `Date()`.
    private static let storeRefreshStartedAt = resetsAt

    @MainActor
    private static func keepAliveSettings(suiteName: String) -> SettingsStore {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.providerDetectionCompleted = true
        if let metadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }
        settings.codexWindowKeepAliveEnabled = true
        settings.refreshFrequency = .fiveMinutes
        settings.backgroundWorkLowPowerModePreference = .off
        settings._test_codexAccountSnapshotLoader = { _ in Self.reconciliationSnapshot(stored: nil) }
        return settings
    }

    @MainActor
    private static func makeStore(settings: SettingsStore) -> UsageStore {
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.snapshots[.codex] = Self.snapshot(primaryResetsAt: Self.resetsAt)
        store.lastSnapshotPublicationAt[.codex] = Date()
        store.codexWindowKeepAliveAuthorityLoader = { Self.authority(environment: $0) }
        return store
    }

    @MainActor
    private static func statusText(
        _ settings: SettingsStore,
        authority: UsageStore.CodexWindowKeepAliveAuthority?) -> String?
    {
        CodexProviderImplementation.windowKeepAliveStatusText(settings: settings, loginAuthority: { authority })
    }

    /// A synthetic ChatGPT login; tests never read a real `auth.json`.
    private static func authority(
        environment: [String: String] = ["CODEX_HOME": "/tmp/codexbar-keepalive-tests/a"],
        authFingerprint: String = "fingerprint-a",
        accountID: String? = "account-a",
        isAPIKeyLogin: Bool = false) -> UsageStore.CodexWindowKeepAliveAuthority
    {
        UsageStore.CodexWindowKeepAliveAuthority(
            environment: environment,
            authFingerprint: authFingerprint,
            accountID: accountID,
            isAPIKeyLogin: isAPIKeyLogin)
    }

    /// Selects an added (managed) account whose stored workspace differs from whatever its auth file names.
    @MainActor
    private static func selectManagedWorkspace(in settings: SettingsStore) {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "account@example.com",
            providerAccountID: "workspace-example",
            managedHomePath: "/tmp/codexbar-window-keepalive-tests/managed",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let snapshot = Self.reconciliationSnapshot(stored: stored)
        settings._test_codexAccountSnapshotLoader = { _ in snapshot }
        settings.codexActiveSource = .managedAccount(id: stored.id)
    }

    private static func reconciliationSnapshot(stored: ManagedCodexAccount?) -> CodexAccountReconciliationSnapshot {
        CodexAccountReconciliationSnapshot(
            storedAccounts: stored.map { [$0] } ?? [],
            activeStoredAccount: stored,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: stored.map { .managedAccount(id: $0.id) } ?? .liveSystem,
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: stored.map { [$0.id: .providerAccount(id: "workspace-example")] } ?? [:])
    }

    private static func context(
        enabled: Bool = true,
        window: UsageStore.ResetBoundaryWindow = Self.window(),
        codexEnabled: Bool = true,
        refreshCadenceIsManual: Bool = false,
        lowPowerModeEnabled: Bool = false,
        selectedManagedWorkspaceID: String? = nil,
        authority: UsageStore.CodexWindowKeepAliveAuthority? = Self.authority(),
        attemptedBoundaries: Set<Date> = [],
        refreshedSnapshot: UsageSnapshot? = Self.snapshot(primaryResetsAt: Self.resetsAt),
        refreshStartedAt: Date = Self.refreshStartedAt,
        snapshotPublishedAt: Date? = Self.freshPublicationAt) -> UsageStore.CodexWindowKeepAliveContext
    {
        UsageStore.CodexWindowKeepAliveContext(
            enabled: enabled,
            window: window,
            codexEnabled: codexEnabled,
            refreshCadenceIsManual: refreshCadenceIsManual,
            lowPowerModeEnabled: lowPowerModeEnabled,
            selectedManagedWorkspaceID: selectedManagedWorkspaceID,
            authority: authority,
            attemptedBoundaries: attemptedBoundaries,
            refreshedSnapshot: refreshedSnapshot,
            refreshStartedAt: refreshStartedAt,
            snapshotPublishedAt: snapshotPublishedAt)
    }

    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool) async throws
    {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for keep-alive ping")
    }

    private static func window(
        instanceID: ProviderInstanceID = .codex,
        windowMinutes: Int? = 300) -> UsageStore.ResetBoundaryWindow
    {
        UsageStore.ResetBoundaryWindow(
            instanceID: instanceID,
            windowMinutes: windowMinutes,
            resetsAt: self.resetsAt)
    }

    private static func snapshot(primaryResetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: primaryResetsAt,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: self.resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds),
            identity: nil)
    }
}

private actor PingCounter {
    private(set) var count = 0
    private(set) var hasPinged = false

    func increment() {
        self.count += 1
        self.hasPinged = true
    }
}
