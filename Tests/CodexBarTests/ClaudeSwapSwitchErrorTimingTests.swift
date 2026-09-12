import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeSwapSwitchErrorTimingTests {
    @Test(arguments: [false, true])
    func `failed switch is visible before ambient refresh finishes`(changeConfiguration: Bool) async throws {
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
        fixture.store.switchClaudeSwapAccount(accountID)
        let task = try #require(fixture.store.claudeSwapTransientState.task)
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
        fixture.store.switchClaudeSwapAccount(accountID)
        if changeConfiguration { fixture.settings.claudeSwapExecutablePath = "/synthetic/reconfigured/cswap" }
        gate.release()
        await task.value
        let calls = try String(contentsOfFile: executable.path + ".calls", encoding: .utf8)
        #expect(calls == "--switch-to\n2\n--json\n")
        #expect(fixture.store.claudeSwapTransientState.task == nil)
        #expect(fixture.store.claudeSwapTransientState.switchingAccountID == nil)
        if changeConfiguration {
            #expect(fixture.store.claudeSwapTransientState.lastError == nil)
            #expect(fixture.store.claudeSwapTransientState.lastErrorAccountID == nil)
        } else {
            #expect(fixture.store.claudeSwapTransientState.lastErrorAccountID == accountID)
        }
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
