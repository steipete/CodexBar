import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// Uses only pre-existing store/task seams so the identical fixture can also prove the unfixed baseline.
@MainActor
final class ClaudeSwapProgressNativeProofFixture {
    let navigation: CodexWorkspacesNavigationFixture
    let executable: URL
    let refreshGate = ClaudeSwapProgressNativeRefreshGate()
    let targetID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2")
    private(set) var savedSwitchTask: Task<Void, Never>?
    private var completionObserver: Task<Void, Never>?
    private(set) var transactionDrained = false
    private(set) var widgetTaskDrained = false
    private(set) var publishedReconciledAccounts = false

    var store: UsageStore {
        self.navigation.store
    }

    var settings: SettingsStore {
        self.navigation.settings
    }

    var subprocessEntered: Bool {
        FileManager.default.fileExists(atPath: self.executable.path + ".entered")
    }

    var subprocessReleased: Bool {
        FileManager.default.fileExists(atPath: self.executable.path + ".release")
    }

    var unexpectedArguments: Bool {
        FileManager.default.fileExists(atPath: self.executable.path + ".unexpected")
    }

    init() throws {
        let navigation = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        self.navigation = navigation
        let executable = navigation.files.root.appendingPathComponent("synthetic-cswap-native")
        self.executable = executable
        let script = #"""
        #!/bin/sh
        if [ "$#" -ne 3 ] || [ "$1" != "--switch-to" ] || [ "$2" != "2" ] || [ "$3" != "--json" ]; then
          printf '%s\n' "$@" > "$0.unexpected"
          exit 64
        fi
        printf '%s\n' "$@" >> "$0.calls"
        touch "$0.entered"
        remaining=4500
        while [ ! -e "$0.release" ] && [ "$remaining" -gt 0 ]; do
          sleep 0.01
          remaining=$((remaining - 1))
        done
        if [ ! -e "$0.release" ]; then exit 65; fi
        echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"switched"}'
        """#
        do {
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        } catch {
            navigation.cleanup()
            throw error
        }
        let settings = navigation.settings
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false
        settings.multiAccountMenuLayout = .segmented
        settings.hidePersonalInfo = true
        settings.usageBarsShowUsed = true
        settings.paceVisible = false
        settings.refreshAllProvidersOnMenuOpen = false
        settings.agentSessionsEnabled = false
        settings.providerStorageFootprintsEnabled = false
        settings.codexCookieSource = .off
        settings.claudeSwapExecutablePath = executable.path
        settings.claudeSwapEnabled = true
        settings.setProviderEnabled(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            enabled: true)
        // A genuine merged menu needs two providers; the auxiliary Codex snapshot is inert and synthetic.
        let store = navigation.store
        store._setSnapshotForTesting(Self.ambientSnapshot(provider: .codex, percent: 29), provider: .codex)
        store._setSnapshotForTesting(Self.ambientSnapshot(provider: .claude, percent: 61), provider: .claude)
        store.claudeSwapAccountSnapshots = Self.accounts(activeSlot: 1)
        store.claudeSwapLastRefreshAt = Date()
        let gate = self.refreshGate
        store._test_providerRefreshOverride = { [weak self] provider in
            guard provider == .claude else {
                gate.requestedUnexpectedProvider = true
                return
            }
            await gate.wait()
            guard let self else { return }
            // Only the held synthetic refresh publishes the new active marker, after the subprocess has exited.
            self.store.claudeSwapAccountSnapshots = Self.accounts(activeSlot: 2)
            self.store.claudeSwapLastRefreshAt = Date()
            self.store.claudeSwapRevision &+= 1
            self.store._setSnapshotForTesting(Self.ambientSnapshot(provider: .claude, percent: 17), provider: .claude)
            self.publishedReconciledAccounts = true
        }
    }

    func observeStartedTransaction() throws {
        let task = try XCTUnwrap(self.store.claudeSwapTransientState.task)
        self.savedSwitchTask = task
        self.completionObserver = Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.transactionDrained = true
            await self.store.widgetSnapshotPersistTask?.value
            self.widgetTaskDrained = true
        }
    }

    func switchArguments() throws -> String {
        let file = URL(fileURLWithPath: self.executable.path + ".calls")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    func releaseSubprocess() throws {
        try Data().write(to: URL(fileURLWithPath: self.executable.path + ".release"), options: .atomic)
    }

    func drainTransaction() async {
        try? self.releaseSubprocess()
        self.refreshGate.release()
        let task = self.savedSwitchTask ?? self.store.claudeSwapTransientState.task
        await task?.value
        await self.completionObserver?.value
        self.transactionDrained = task != nil
        await self.store.widgetSnapshotPersistTask?.value
        self.widgetTaskDrained = true
    }

    func drainAndCleanup() async {
        await self.drainTransaction()
        self.store._test_providerRefreshOverride = nil
        self.navigation.cleanup()
    }

    private static func accounts(activeSlot: Int) -> [ProviderAccountUsageSnapshot] {
        ClaudeSwapAccountProjection.accountSnapshots(from: .init(
            activeAccountNumber: activeSlot,
            accounts: [(1, 61.0), (2, 17.0), (3, 48.0)].map { number, percent in
                .init(
                    number: number,
                    email: "synthetic-account-\(number)@example.invalid",
                    isActive: number == activeSlot,
                    usageStatus: .ok,
                    fiveHour: .init(usedPercent: percent, resetsAt: Date().addingTimeInterval(3600)),
                    sevenDay: nil)
            }))
    }

    private static func ambientSnapshot(provider: UsageProvider, percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: percent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: .init(
                providerID: provider.instanceID,
                accountEmail: "synthetic-ambient@example.invalid",
                accountOrganization: nil,
                loginMethod: "Synthetic"))
    }
}

@MainActor
final class ClaudeSwapProgressNativeRefreshGate {
    private(set) var entered = false
    private(set) var released = false
    private(set) var callCount = 0
    var requestedUnexpectedProvider = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        self.entered = true
        self.callCount += 1
        guard !self.released else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func release() {
        self.released = true
        for continuation in self.continuations {
            continuation.resume()
        }
        self.continuations.removeAll()
    }
}
