import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
final class ClaudeSwapReconciliationFixture {
    let navigation: CodexWorkspacesNavigationFixture
    let executable: URL
    let ambientGate = ClaudeSwapReconciliationAmbientGate()
    let targetID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2")
    let thirdID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "3")
    private var executables: [URL] = []
    private var savedSwitchTask: Task<Void, Never>?
    private var completionObserver: Task<Void, Never>?
    private var adapterTasks: [Task<Void, Never>] = []
    private(set) var switchCompleted = false
    private(set) var phases: [ClaudeSwapSwitchPhase?] = []

    var settings: SettingsStore {
        self.navigation.settings
    }

    var store: UsageStore {
        self.navigation.store
    }

    var activeSlots: [String] {
        self.store.claudeSwapAccountSnapshots.filter(\.isActive).map(\.id.opaqueID)
    }

    init(failure: ClaudeSwapReconciliationFailure) throws {
        self.navigation = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        self.executable = self.navigation.files.root.appendingPathComponent("cswap-reconciliation")
        self.executables = [self.executable]
        do {
            try Self.writeExecutable(self.executable, failure: failure)
            let settings = self.settings
            settings.claudeUsageDataSource = .api
            settings.claudeCookieSource = .off
            settings.claudeWebExtrasEnabled = false
            settings.claudeSwapExecutablePath = self.executable.path
            settings.claudeSwapEnabled = true
            settings.setProviderEnabled(
                provider: .claude,
                metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
                enabled: true)
            self.store.claudeSwapAccountSnapshots = try ClaudeSwapAccountProjection.accountSnapshots(
                from: ClaudeSwapListParser.parse(Self.listData(activeSlot: 1)))
            self.store._test_providerRefreshOverride = nil
            for provider in [UsageProvider.claude, .codex] {
                let spec = try #require(self.store.providerSpecs[provider])
                let base = spec.descriptor
                let strategy = ClaudeSwapReconciliationAmbientStrategy(
                    provider: provider,
                    gate: self.ambientGate,
                    percent: failure.switchFails ? 61 : 17)
                let descriptor = ProviderDescriptor(
                    id: provider,
                    metadata: base.metadata,
                    branding: base.branding,
                    tokenCost: base.tokenCost,
                    pace: base.pace,
                    history: base.history,
                    presentation: base.presentation,
                    fetchPlan: ProviderFetchPlan(
                        sourceModes: [.api],
                        pipeline: ProviderFetchPipeline { _ in [strategy] }),
                    cli: base.cli)
                self.store.providerSpecs[provider] = ProviderSpec(
                    style: spec.style,
                    isEnabled: spec.isEnabled,
                    descriptor: descriptor,
                    makeFetchContext: spec.makeFetchContext)
            }
        } catch {
            self.navigation.cleanup()
            throw error
        }
    }

    func startSwitch() throws -> Task<Void, Never> {
        self.store.switchClaudeSwapAccount(self.targetID, progressDidChange: { [weak self] in
            guard let self else { return }
            self.phases.append(self.store.claudeSwapTransientState.switchPhase)
        })
        let task = try #require(self.store.claudeSwapTransientState.task)
        self.savedSwitchTask = task
        self.completionObserver = Task { @MainActor [weak self] in
            await task.value
            self?.switchCompleted = true
        }
        return task
    }

    func waitForBothReads() async throws {
        try await self.waitUntil { self.ambientGate.entered && self.listEntered(1) }
    }

    func currentAdapterTask() throws -> Task<Void, Never> {
        let task = try #require(self.store.claudeSwapRefreshTask)
        self.adapterTasks.append(task)
        return task
    }

    func finishAmbientRefresh() async throws {
        let refresh = try #require(self.store.providerRefreshCoordinator.coalescingState(for: .claude))
        self.ambientGate.release()
        await refresh.waitForTaskCompletion()
        // Give the switch task waiting on the ambient coordinator its continuation turn.
        for _ in 0..<4 {
            await Task.yield()
        }
        #expect(!self.store.refreshingProviders.contains(.claude))
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

    func listEntered(_ number: Int, executable: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (executable ?? self.executable).path + ".list-\(number).entered")
    }

    func releaseList(_ number: Int, executable: URL? = nil) throws {
        try Data().write(to: URL(fileURLWithPath: (executable ?? self.executable).path + ".list-\(number).release"))
    }

    func switchArguments() throws -> String { try self.readSuffix("switch-calls") }

    func readSuffix(_ suffix: String) throws -> String {
        try String(contentsOfFile: self.executable.path + "." + suffix, encoding: .utf8)
    }

    func makeReplacementExecutable() throws -> URL {
        let replacement = self.navigation.files.root.appendingPathComponent("cswap-new-configuration")
        try Self.writeExecutable(replacement, failure: .none)
        self.executables.append(replacement)
        return replacement
    }

    func cleanup() async {
        self.ambientGate.release()
        for executable in self.executables {
            for number in 1...3 {
                try? self.releaseList(number, executable: executable)
            }
        }
        await self.savedSwitchTask?.value
        await self.completionObserver?.value
        await self.store.claudeSwapTransientState.task?.value
        for task in self.adapterTasks {
            await task.value
        }
        await self.store.claudeSwapRefreshTask?.value
        await self.store.widgetSnapshotPersistTask?.value
        #expect(!self.ambientGate.requestedUnexpectedProvider)
        #expect(self.ambientGate.callCount == 1)
        for executable in self.executables {
            #expect(!FileManager.default.fileExists(atPath: executable.path + ".unexpected"))
        }
        self.navigation.cleanup()
    }

    private static func writeExecutable(_ executable: URL, failure: ClaudeSwapReconciliationFailure) throws {
        let script = #"""
        #!/bin/sh
        if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
          printf '%s\n' "$@" >> "$0.version-calls"
          echo 'cswap 0.0.0-synthetic'
          exit 0
        fi
        if [ "$#" -eq 3 ] && [ "$1" = "--switch-to" ] && [ "$2" = "2" ] && [ "$3" = "--json" ]; then
          printf '%s\n' "$@" >> "$0.switch-calls"
          if [ -e "$0.switch-error" ]; then
            echo '{"schemaVersion":1,"error":{"type":"SwitchError","message":"credentials missing"}}'
            exit 1
          fi
          echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"switched"}'
          exit 0
        fi
        if [ "$#" -eq 2 ] && [ "$1" = "--list" ] && [ "$2" = "--json" ]; then
          printf '%s\n' "$@" >> "$0.list-calls"
          list_number=0
          if [ -f "$0.list-count" ]; then list_number=$(cat "$0.list-count"); fi
          list_number=$((list_number + 1))
          printf '%s' "$list_number" > "$0.list-count"
          touch "$0.list-$list_number.entered"
          remaining=1500
          while [ ! -e "$0.list-$list_number.release" ] && [ "$remaining" -gt 0 ]; do
            sleep 0.01
            remaining=$((remaining - 1))
          done
          if [ ! -e "$0.list-$list_number.release" ]; then exit 65; fi
          if [ -e "$0.list-error" ]; then
            echo '{"schemaVersion":1,"error":{"type":"ListError","message":"list unavailable"}}'
            exit 1
          fi
          exec /bin/cat "$0.accounts.json"
        fi
        printf '%s\n' "$@" > "$0.unexpected"
        exit 64
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Self.listData(activeSlot: failure.switchFails ? 1 : 2)
            .write(to: URL(fileURLWithPath: executable.path + ".accounts.json"))
        if failure.switchFails { try Data().write(to: URL(fileURLWithPath: executable.path + ".switch-error")) }
        if failure.listFails { try Data().write(to: URL(fileURLWithPath: executable.path + ".list-error")) }
    }

    private static func listData(activeSlot: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "activeAccountNumber": activeSlot,
            "accounts": [(1, 61), (2, 17), (3, 48)].map { number, percent -> [String: Any] in
                [
                    "number": number,
                    "email": "synthetic-\(number)@example.invalid",
                    "organizationName": "",
                    "active": number == activeSlot,
                    "usageStatus": "ok",
                    "usage": ["fiveHour": [
                        "pct": percent,
                        "resetsAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
                    ]],
                ]
            },
        ])
    }
}

@MainActor
final class ClaudeSwapReconciliationAmbientGate {
    private(set) var entered = false
    private(set) var callCount = 0
    private(set) var requestedUnexpectedProvider = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        self.entered = true
        self.callCount += 1
        guard !self.released else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func rejectUnexpectedProvider() { self.requestedUnexpectedProvider = true }

    func release() {
        self.released = true
        for continuation in self.continuations {
            continuation.resume()
        }
        self.continuations.removeAll()
    }
}

private struct ClaudeSwapReconciliationAmbientStrategy: ProviderFetchStrategy {
    let provider: UsageProvider
    let gate: ClaudeSwapReconciliationAmbientGate
    let percent: Double
    let id = "synthetic-claude-reconciliation"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard self.provider == .claude else {
            await self.gate.rejectUnexpectedProvider()
            throw URLError(.unsupportedURL)
        }
        await self.gate.wait()
        return self.makeResult(
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: self.percent,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: .init(
                    providerID: .claude,
                    accountEmail: "synthetic-ambient@example.invalid",
                    accountOrganization: nil,
                    loginMethod: "Synthetic")),
            sourceLabel: "synthetic-claude-reconciliation")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}
