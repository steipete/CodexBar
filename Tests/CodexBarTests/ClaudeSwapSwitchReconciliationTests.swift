import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeSwapSwitchReconciliationTests {
    @Test(arguments: ClaudeSwapReconciliationFailure.allCases)
    func `ambient completion keeps switching serialized until the real adapter list finishes`(
        failure: ClaudeSwapReconciliationFailure) async throws
    {
        try await self.withFixture(failure: failure) { fixture in
            let task = try fixture.startSwitch()
            try await fixture.waitForBothReads()
            try await fixture.finishAmbientRefresh()
            #expect(fixture.store.snapshot(for: .claude)?.primary?.usedPercent == (failure.switchFails ? 61 : 17))
            #expect(fixture.store.claudeSwapTransientState.switchPhase == .reconciling)
            #expect(fixture.store.claudeSwapTransientState.switchingAccountID == fixture.targetID)
            #expect(fixture.store.claudeSwapTransientState.task != nil)
            #expect(!fixture.switchCompleted)
            #expect(fixture.activeSlots == ["1"])
            #expect(fixture.phases == [.activating, .reconciling])
            if failure.switchFails {
                #expect(fixture.store.claudeSwapTransientState.lastError?.contains("credentials missing") == true)
            }
            fixture.store.switchClaudeSwapAccount(fixture.targetID)
            fixture.store.switchClaudeSwapAccount(fixture.thirdID)
            #expect(try fixture.switchArguments() == "--switch-to\n2\n--json\n")

            try fixture.releaseList(1)
            await task.value
            #expect(fixture.phases == [.activating, .reconciling, nil])
            #expect(fixture.store.claudeSwapTransientState.task == nil)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
            #expect(fixture.store.claudeSwapTransientState.switchingAccountID == nil)
            #expect(fixture.activeSlots == (failure.switchFails || failure.listFails ? ["1"] : ["2"]))
            #expect(fixture.store.claudeSwapDetectedVersion == "0.0.0-synthetic")
            #expect(try fixture.readSuffix("version-calls") == "--version\n")
            #expect(try fixture.readSuffix("list-calls") == "--list\n--json\n")
            #expect(try fixture.switchArguments() == "--switch-to\n2\n--json\n")
            #expect(fixture.ambientGate.callCount == 1)
            #expect(!fixture.ambientGate.requestedUnexpectedProvider)
            #expect((fixture.store.claudeSwapTransientState.lastError != nil) == failure.switchFails)
            #expect((fixture.store.claudeSwapLastError != nil) == failure.listFails)
            if failure.switchFails {
                let error = ClaudeSwapAccountProjection.displayError(
                    accountError: nil,
                    adapterError: fixture.store.claudeSwapLastError,
                    switchError: fixture.store.claudeSwapTransientState.lastError)
                #expect(error?.contains("credentials missing") == true)
                #expect(error?.contains("list unavailable") == false)
            }
        }
    }

    @Test
    func `same configuration list replacement remains part of switch reconciliation`() async throws {
        try await self.withFixture { fixture in
            let task = try fixture.startSwitch()
            try await fixture.waitForBothReads()
            try await fixture.finishAmbientRefresh()
            let firstList = try fixture.currentAdapterTask()
            fixture.store.scheduleClaudeSwapAccountRefresh()
            try await fixture.waitUntil { fixture.listEntered(2) }
            await firstList.value
            await Task.yield()
            #expect(firstList.isCancelled)
            #expect(fixture.store.claudeSwapTransientState.task != nil)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == .reconciling)
            #expect(fixture.store.claudeSwapTransientState.switchingAccountID == fixture.targetID)
            #expect(!fixture.switchCompleted)
            #expect(fixture.activeSlots == ["1"])
            fixture.store.switchClaudeSwapAccount(fixture.thirdID)
            try fixture.releaseList(2)
            await task.value
            #expect(fixture.activeSlots == ["2"])
            #expect(fixture.store.claudeSwapTransientState.task == nil)
            #expect(fixture.phases == [.activating, .reconciling, nil])
            #expect(try fixture.readSuffix("list-calls") == "--list\n--json\n--list\n--json\n")
            #expect(try fixture.switchArguments() == "--switch-to\n2\n--json\n")
        }
    }

    @Test(arguments: [false, true])
    func `invalidated switch does not join a new configuration adapter read`(changePath: Bool) async throws {
        try await self.withFixture(failure: .switchFailure) { fixture in
            let task = try fixture.startSwitch()
            try await fixture.waitForBothReads()
            try await fixture.finishAmbientRefresh()
            let oldList = try fixture.currentAdapterTask()
            fixture.settings.claudeSwapEnabled = false
            fixture.store.clearClaudeSwapAccountState()
            let replacement: URL = if changePath {
                try fixture.makeReplacementExecutable()
            } else {
                fixture.executable
            }
            fixture.settings.claudeSwapExecutablePath = replacement.path
            fixture.settings.claudeSwapEnabled = true
            fixture.store.scheduleClaudeSwapAccountRefresh()
            let nextListNumber = changePath ? 1 : 2
            try await fixture.waitUntil { fixture.listEntered(nextListNumber, executable: replacement) }
            let newList = try fixture.currentAdapterTask()
            try await fixture.waitUntil { fixture.switchCompleted }
            await task.value
            await oldList.value
            #expect(oldList.isCancelled)
            #expect(!task.isCancelled)
            #expect(!newList.isCancelled)
            #expect(fixture.store.claudeSwapRefreshTask == newList)
            #expect(fixture.store.claudeSwapAccountSnapshots.isEmpty)
            #expect(fixture.store.claudeSwapTransientState.task == nil)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
            #expect(fixture.store.claudeSwapTransientState.switchingAccountID == nil)
            #expect(fixture.store.claudeSwapTransientState.lastError == nil)
            #expect(fixture.phases == [.activating, .reconciling])
            try fixture.releaseList(nextListNumber, executable: replacement)
            await newList.value
            #expect(fixture.store.claudeSwapAccountSnapshots.count == 3)
            #expect(fixture.store.claudeSwapTransientState.lastError == nil)
        }
    }

    private nonisolated func withFixture(
        failure: ClaudeSwapReconciliationFailure = .none,
        _ body: @MainActor @Sendable (ClaudeSwapReconciliationFixture) async throws -> Void) async throws
    {
        let fixture = try await MainActor.run { try ClaudeSwapReconciliationFixture(failure: failure) }
        let credentialsURL = await MainActor.run {
            fixture.navigation.files.root.appendingPathComponent("missing-claude-credentials.json")
        }
        do {
            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
                    try await body(fixture)
                }
            }
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }
}

enum ClaudeSwapReconciliationFailure: CaseIterable, Equatable, Sendable {
    case none
    case switchFailure
    case listFailure
    case switchAndListFailure

    var switchFails: Bool {
        self == .switchFailure || self == .switchAndListFailure
    }

    var listFails: Bool {
        self == .listFailure || self == .switchAndListFailure
    }
}
