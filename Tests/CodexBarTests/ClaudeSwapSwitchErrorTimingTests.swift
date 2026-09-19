import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeSwapSwitchErrorTimingTests {
    @Test
    func `active foreign credential repair uses the existing exact slot command`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let executable = fixture.files.root.appendingPathComponent("cswap-repair")
        let script = #"""
        #!/bin/sh
        if [ "$#" -ne 3 ] || [ "$1" != "--switch-to" ] || [ "$2" != "1" ] || [ "$3" != "--json" ]; then
          exit 64
        fi
        printf '%s\n' "$@" > "$0.calls"
        echo '{"schemaVersion":1,"switched":false,"from":{"number":1},"to":{"number":1},"reason":"already-active"}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let gate = RefreshGate()
        gate.release()
        fixture.store._test_providerRefreshOverride = { provider in
            #expect(provider == .claude)
            await gate.wait()
        }
        defer { fixture.store._test_providerRefreshOverride = nil }
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        fixture.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        fixture.settings.claudeSwapExecutablePath = executable.path
        fixture.settings.claudeSwapEnabled = true
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: .init(
            activeAccountNumber: 1,
            accounts: [.init(
                number: 1,
                email: "fixture@example.invalid",
                isActive: true,
                usageStatus: .foreignCredential,
                fiveHour: nil,
                sevenDay: nil)])).first)
        fixture.store.claudeSwapAccountSnapshots = [account]
        #expect(account.canActivate)
        #expect(ClaudeSwapAccountMenuDisplay.actionLabel(
            for: account,
            switchingAccountID: nil,
            switchInFlight: false,
            switchPhase: nil) == L("Re-authenticate"))
        fixture.store.switchClaudeSwapAccount(account.id)
        let task = try #require(fixture.store.claudeSwapTransientState.task)
        await task.value
        #expect(gate.entered)
        #expect(try String(contentsOfFile: executable.path + ".calls", encoding: .utf8) == "--switch-to\n1\n--json\n")
        #expect(fixture.store.claudeSwapTransientState.lastError == nil)
        #expect(fixture.store.claudeSwapTransientState.task == nil)
    }

    @Test(arguments: ConfigurationChange.allCases)
    func `failed switch is visible before ambient refresh finishes`(
        configurationChange: ConfigurationChange) async throws
    {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let executable = fixture.files.root.appendingPathComponent("cswap")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> "${0}.calls"
        echo '{"schemaVersion":1,"error":{"type":"SwitchError","message":"credentials missing"}}'
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        fixture.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        fixture.settings.claudeSwapExecutablePath = executable.path
        fixture.settings.claudeSwapEnabled = true
        let accountID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2")
        fixture.store.claudeSwapAccountSnapshots = [.init(
            id: accountID,
            provider: .claude,
            displayLabel: "Synthetic account",
            isActive: false,
            canActivate: true,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)]
        let gate = RefreshGate()
        fixture.store._test_providerRefreshOverride = { provider in
            #expect(provider == .claude)
            await gate.wait()
        }
        defer {
            gate.release()
            fixture.store._test_providerRefreshOverride = nil
        }
        let progress = ProgressRecorder()
        fixture.store.switchClaudeSwapAccount(accountID, progressDidChange: {
            progress.phases.append(fixture.store.claudeSwapTransientState.switchPhase)
        })
        let task = try #require(fixture.store.claudeSwapTransientState.task)
        #expect(fixture.store.claudeSwapTransientState.switchPhase == .activating)
        #expect(progress.phases == [.activating])
        let startedRevision = fixture.store.claudeSwapRevision
        let deadline = Date().addingTimeInterval(8)
        while !gate.entered, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.entered)
        #expect(fixture.store.claudeSwapRevision > startedRevision)
        #expect(fixture.store.claudeSwapTransientState.lastError?.contains("credentials missing") == true)
        #expect(fixture.store.claudeSwapTransientState.lastErrorAccountID == accountID)
        #expect(fixture.store.claudeSwapTransientState.task != nil)
        #expect(fixture.store.claudeSwapTransientState.switchPhase == .reconciling)
        #expect(progress.phases == [.activating, .reconciling])
        fixture.store.switchClaudeSwapAccount(accountID)
        switch configurationChange {
        case .unchanged:
            break
        case .differentPath:
            fixture.settings.claudeSwapExecutablePath = "/synthetic/reconfigured/cswap"
        case .disabledThenRestored:
            let accounts = fixture.store.claudeSwapAccountSnapshots
            fixture.settings.claudeSwapEnabled = false
            // Testing startup leaves provider runtimes idle; perform their configuration invalidation explicitly.
            fixture.store.clearClaudeSwapAccountState()
            fixture.settings.claudeSwapEnabled = true
            fixture.store.claudeSwapAccountSnapshots = accounts
            #expect(fixture.store.claudeSwapTransientState.task != nil)
            #expect(!task.isCancelled)
            #expect(fixture.store.claudeSwapTransientState.switchingAccountID == nil)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
            #expect(fixture.store.claudeSwapTransientState.lastError == nil)
            fixture.store.switchClaudeSwapAccount(accountID)
        }
        gate.release()
        await task.value
        let calls = try String(contentsOfFile: executable.path + ".calls", encoding: .utf8)
        #expect(calls == "--switch-to\n2\n--json\n")
        #expect(fixture.store.claudeSwapTransientState.task == nil)
        #expect(fixture.store.claudeSwapTransientState.switchingAccountID == nil)
        #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
        if configurationChange != .unchanged {
            #expect(fixture.store.claudeSwapTransientState.lastError == nil)
            #expect(fixture.store.claudeSwapTransientState.lastErrorAccountID == nil)
            #expect(progress.phases == [.activating, .reconciling])
        } else {
            #expect(fixture.store.claudeSwapTransientState.lastErrorAccountID == accountID)
            #expect(progress.phases == [.activating, .reconciling, nil])
        }
    }

    @Test(arguments: [false, true])
    func `successful activation reports reconciliation without inventing an active account`(
        invalidateDuringActivation: Bool) async throws
    {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let executable = fixture.files.root.appendingPathComponent("cswap-success")
        let script = #"""
        #!/bin/sh
        if [ "$#" -ne 3 ] || [ "$1" != "--switch-to" ] || [ "$2" != "2" ] || [ "$3" != "--json" ]; then
          exit 64
        fi
        printf '%s\n' "$@" >> "$0.calls"
        echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"switched"}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        fixture.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        fixture.settings.claudeSwapExecutablePath = executable.path
        fixture.settings.claudeSwapEnabled = true
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: .init(
            activeAccountNumber: 1,
            accounts: [1, 2].map { number in
                .init(
                    number: number,
                    email: "fixture\(number)@example.invalid",
                    isActive: number == 1,
                    usageStatus: .ok,
                    fiveHour: .init(usedPercent: Double(number * 17), resetsAt: nil),
                    sevenDay: nil)
            }))
        fixture.store.claudeSwapAccountSnapshots = accounts
        let target = try #require(accounts.first { $0.id.opaqueID == "2" })
        let gate = RefreshGate()
        fixture.store._test_providerRefreshOverride = { provider in
            #expect(provider == .claude)
            await gate.wait()
        }
        defer {
            gate.release()
            fixture.store._test_providerRefreshOverride = nil
        }
        let progress = ProgressRecorder()
        fixture.store.switchClaudeSwapAccount(target.id, progressDidChange: {
            progress.phases.append(fixture.store.claudeSwapTransientState.switchPhase)
        })
        let task = try #require(fixture.store.claudeSwapTransientState.task)
        #expect(progress.phases == [.activating])
        fixture.store.switchClaudeSwapAccount(target.id)
        if invalidateDuringActivation {
            fixture.settings.claudeSwapEnabled = false
            fixture.store.clearClaudeSwapAccountState()
            fixture.settings.claudeSwapEnabled = true
            fixture.store.claudeSwapAccountSnapshots = accounts
            #expect(fixture.store.claudeSwapTransientState.task != nil)
            #expect(!task.isCancelled)
            #expect(fixture.store.claudeSwapTransientState.switchingAccountID == nil)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
            fixture.store.switchClaudeSwapAccount(target.id)
            gate.release()
            await task.value
            #expect(!gate.entered)
            #expect(progress.phases == [.activating])
            #expect(fixture.store.claudeSwapTransientState.task == nil)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
            #expect(fixture.store.claudeSwapTransientState.lastError == nil)
            #expect(try String(contentsOfFile: executable.path + ".calls", encoding: .utf8) ==
                "--switch-to\n2\n--json\n")
            return
        }
        let deadline = Date().addingTimeInterval(8)
        while !gate.entered, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.entered)
        #expect(progress.phases == [.activating, .reconciling])
        #expect(fixture.store.claudeSwapTransientState.task != nil)
        #expect(fixture.store.claudeSwapTransientState.switchingAccountID == target.id)
        #expect(fixture.store.claudeSwapTransientState.lastError == nil)
        #expect(fixture.store.claudeSwapAccountSnapshots.first(where: \.isActive)?.id.opaqueID == "1")
        let targetSnapshot = fixture.store.claudeSwapAccountSnapshots.first { $0.id == target.id }?.snapshot
        #expect(targetSnapshot?.primary?.usedPercent == 34)
        fixture.store.switchClaudeSwapAccount(target.id)
        gate.release()
        await task.value
        #expect(progress.phases == [.activating, .reconciling, nil])
        #expect(fixture.store.claudeSwapTransientState.task == nil)
        #expect(fixture.store.claudeSwapTransientState.switchingAccountID == nil)
        #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
        #expect(fixture.store.claudeSwapAccountSnapshots.first(where: \.isActive)?.id.opaqueID == "1")
        #expect(try String(contentsOfFile: executable.path + ".calls", encoding: .utf8) == "--switch-to\n2\n--json\n")
    }

    @Test
    func `cancelled independent adapter reads cannot publish`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        fixture.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        fixture.settings.claudeSwapEnabled = true
        let path = "/synthetic/read-only-cswap"
        fixture.settings.claudeSwapExecutablePath = path
        #expect(fixture.store.isCurrentClaudeSwapRefresh(executablePath: path, generation: nil))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return fixture.store.isCurrentClaudeSwapRefresh(executablePath: path, generation: nil)
        }
        #expect(await cancelled.value == false)
    }

    @MainActor
    private final class ProgressRecorder {
        var phases: [ClaudeSwapSwitchPhase?] = []
    }

    enum ConfigurationChange: CaseIterable, Equatable, Sendable {
        case unchanged
        case differentPath
        case disabledThenRestored
    }

    @MainActor
    private final class RefreshGate {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            self.entered = true
            guard !self.released else { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func release() {
            self.released = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}
