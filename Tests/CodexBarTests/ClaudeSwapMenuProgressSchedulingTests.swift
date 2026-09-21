import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ClaudeSwapMenuProgressSchedulingTests {
    @Test
    func `rejected retained card action preserves later account progress rebuilds`() async throws {
        try await self.withFixture { fixture in
            let action = try #require(fixture.controller.claudeSwapAccountSwitchAction(
                fixture.target, menu: fixture.menu))
            action()
            let task = try #require(fixture.store.claudeSwapTransientState.task)
            let generation = try #require(fixture.controller.menuSession.menuInteractionGeneration(
                for: ObjectIdentifier(fixture.menu)))

            // The same card closure can outlive its enabled button until the scheduled rebuild runs.
            action()
            #expect(fixture.controller.menuSession.menuInteractionGeneration(
                for: ObjectIdentifier(fixture.menu)) == generation)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == .activating)
            Self.drainTracking()
            #expect(fixture.rebuildPhases == [.activating])

            try await Self.waitUntil { fixture.subprocessStarted }
            try fixture.releaseSubprocess()
            try await Self.waitUntil { fixture.gate.entered }
            Self.drainTracking()
            #expect(fixture.rebuildPhases == [.activating, .reconciling])
            #expect(fixture.store.claudeSwapTransientState.task != nil)
            #expect(fixture.store.claudeSwapAccountSnapshots.first(where: \.isActive)?.id == fixture.active.id)

            fixture.gate.release()
            await task.value
            Self.drainTracking()
            #expect(fixture.rebuildPhases == [.activating, .reconciling, nil])
            #expect(fixture.store.claudeSwapTransientState.task == nil)
            #expect(fixture.gate.callCount == 1)
            #expect(try String(contentsOf: fixture.callsURL, encoding: .utf8) == "--switch-to\n2\n--json\n")
        }
    }

    @Test(arguments: Invalidation.allCases)
    func `queued account progress cannot overwrite a changed menu context`(invalidation: Invalidation) async throws {
        try await self.withFixture { fixture in
            let action = try #require(fixture.controller.claudeSwapAccountSwitchAction(
                fixture.target, menu: fixture.menu))
            action()
            let task = try #require(fixture.store.claudeSwapTransientState.task)
            #expect(fixture.controller.menuNeedsRefresh(fixture.menu))

            // Invalidate after the real activation callback enqueues work, before its run-loop turn.
            switch invalidation {
            case .configuration:
                fixture.store.clearClaudeSwapAccountState()
            case .provider:
                fixture.controller.selectedMenuProvider = .codex
            case .interaction:
                fixture.controller.advanceMenuInteraction(for: fixture.menu)
            case .inspection:
                fixture.controller.claudeSwapInspectedAccountID = fixture.active.id
            }
            Self.drainTracking()
            #expect(fixture.rebuildPhases.isEmpty)

            try fixture.releaseSubprocess()
            if invalidation != .configuration {
                try await Self.waitUntil { fixture.gate.entered }
                Self.drainTracking()
                #expect(fixture.rebuildPhases.isEmpty)
            }
            fixture.gate.release()
            await task.value
            Self.drainTracking()
            #expect(fixture.rebuildPhases.isEmpty)
            #expect(fixture.store.claudeSwapTransientState.task == nil)
            #expect(fixture.store.claudeSwapTransientState.switchPhase == nil)
            #expect(fixture.gate.callCount == (invalidation == .configuration ? 0 : 1))
        }
    }

    enum Invalidation: CaseIterable, Equatable, Sendable {
        case configuration
        case provider
        case interaction
        case inspection
    }

    private func withFixture(_ body: (ClaudeSwapMenuProgressFixture) async throws -> Void) async throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        let previousRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousRefresh)
        }
        let fixture = try ClaudeSwapMenuProgressFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

    private static func drainTracking() {
        CFRunLoopRunInMode(CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString), 0.1, true)
    }
}

@MainActor
private final class ClaudeSwapMenuProgressFixture {
    let navigation: CodexWorkspacesNavigationFixture
    let controller: StatusItemController
    let menu: NSMenu
    let executable: URL
    let gate: ClaudeSwapMenuProgressGate
    let active: ProviderAccountUsageSnapshot
    let target: ProviderAccountUsageSnapshot
    var rebuildPhases: [ClaudeSwapSwitchPhase?] = []

    var store: UsageStore {
        self.navigation.store
    }

    var callsURL: URL {
        URL(fileURLWithPath: self.executable.path + ".calls")
    }

    var subprocessStarted: Bool {
        FileManager.default.fileExists(atPath: self.executable.path + ".entered")
    }

    init() throws {
        let navigation = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        self.navigation = navigation
        let executable = navigation.files.root.appendingPathComponent("cswap-menu-progress")
        self.executable = executable
        let active = Self.account(slot: "1", active: true)
        let target = Self.account(slot: "2", active: false)
        self.active = active
        self.target = target
        let gate = ClaudeSwapMenuProgressGate()
        self.gate = gate
        let script = #"""
        #!/bin/sh
        if [ "$#" -ne 3 ] || [ "$1" != "--switch-to" ] || [ "$2" != "2" ] || [ "$3" != "--json" ]; then
          exit 64
        fi
        printf '%s\n' "$@" >> "$0.calls"
        touch "$0.entered"
        remaining=800
        while [ ! -e "$0.release" ] && [ "$remaining" -gt 0 ]; do
          sleep 0.01
          remaining=$((remaining - 1))
        done
        if [ ! -e "$0.release" ]; then exit 65; fi
        echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"switched"}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let settings = navigation.settings
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false
        settings.multiAccountMenuLayout = .stacked
        settings.agentSessionsEnabled = false
        settings.claudeSwapExecutablePath = executable.path
        settings.claudeSwapEnabled = true
        settings.setProviderEnabled(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            enabled: true)
        navigation.store.claudeSwapAccountSnapshots = [active, target]
        navigation.store._test_providerRefreshOverride = { provider in
            #expect(provider == .claude)
            await gate.wait()
        }
        let controller = navigation.makeController()
        self.controller = controller
        self.menu = controller.makeMenu(for: .claude)
        // Register only menu lifecycle state; unrelated menu-open refreshes are outside this wiring regression.
        self.controller.mergedMenu = self.menu
        self.controller.beginMenuTrackingSession(for: self.menu)
        self.controller.openMenus[ObjectIdentifier(self.menu)] = self.menu
        self.controller.markMenuFresh(self.menu)
        self.controller._test_openMenuRebuildObserver = { [weak self] rebuilt in
            guard let self else { return }
            #expect(rebuilt === self.menu)
            self.rebuildPhases.append(self.store.claudeSwapTransientState.switchPhase)
        }
    }

    func releaseSubprocess() throws {
        try Data().write(to: URL(fileURLWithPath: self.executable.path + ".release"))
    }

    func cleanup() async {
        try? self.releaseSubprocess()
        self.gate.release()
        await self.store.claudeSwapTransientState.task?.value
        self.controller._test_openMenuRebuildObserver = nil
        self.controller.releaseStatusItemsForTesting()
        self.store._test_providerRefreshOverride = nil
        await self.store.widgetSnapshotPersistTask?.value
        self.navigation.cleanup()
    }

    private static func account(slot: String, active: Bool) -> ProviderAccountUsageSnapshot {
        .init(
            id: .init(source: ClaudeSwapAccountProjection.sourceName, opaqueID: slot),
            provider: .claude,
            displayLabel: "account-\(slot)@example.invalid",
            isActive: active,
            canActivate: !active,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
    }
}

@MainActor
private final class ClaudeSwapMenuProgressGate {
    private(set) var entered = false
    private(set) var callCount = 0
    private var released = false
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
