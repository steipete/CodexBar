import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeProviderRuntimeTests {
    @Test
    func `disabling adapter immediately clears retained accounts`() {
        let (settings, store) = self.makeStore()
        store.claudeSwapAccountSnapshots = [self.accountSnapshot()]
        store.claudeSwapLastRefreshAt = Date()
        store.claudeSwapLastError = "stale"
        let runtime = ClaudeProviderRuntime()

        runtime.settingsDidChange(context: ProviderRuntimeContext(provider: .claude, settings: settings, store: store))

        #expect(store.claudeSwapAccountSnapshots.isEmpty)
        #expect(store.claudeSwapLastRefreshAt == nil)
        #expect(store.claudeSwapLastError == nil)
    }

    @Test
    func `disabled Claude provider does not restart adapter`() {
        let (settings, store) = self.makeStore()
        settings.claudeSwapExecutablePath = "/path/to/cswap"
        settings.claudeSwapEnabled = true
        let runtime = ClaudeProviderRuntime()
        let context = ProviderRuntimeContext(provider: .claude, settings: settings, store: store)

        runtime.stop(context: context)
        runtime.settingsDidChange(context: context)

        #expect(!store.isEnabled(.claude))
        #expect(store.claudeSwapRefreshTask == nil)
    }

    @Test
    func `late adapter result is rejected after executable path changes`() async throws {
        let (settings, store) = self.makeStore()
        let executable = try self.makeFakeExecutable()
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        settings.claudeSwapExecutablePath = executable
        settings.claudeSwapEnabled = true

        let refresh = Task { @MainActor in
            await store.refreshClaudeSwapAccounts()
        }
        try await Task.sleep(for: .milliseconds(100))
        settings.claudeSwapExecutablePath = "/new/path/to/cswap"
        await refresh.value

        #expect(store.claudeSwapAccountSnapshots.isEmpty)
        #expect(store.claudeSwapLastRefreshAt == nil)
    }

    @Test
    func `explicit account activation is serialized through claude swap and refreshes Claude`() async throws {
        let (settings, store) = self.makeStore()
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-switch-args-\(UUID().uuidString)")
        let executable = try self.makeSwitchExecutable(marker: marker)
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        settings.claudeSwapExecutablePath = executable
        settings.claudeSwapEnabled = true
        let accountID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2")
        store.claudeSwapAccountSnapshots = [ProviderAccountUsageSnapshot(
            id: accountID,
            provider: .claude,
            displayLabel: "switch@example.com",
            isActive: false,
            canActivate: true,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)]
        var refreshedProviders: [UsageProvider] = []
        store._test_providerRefreshOverride = { refreshedProviders.append($0) }
        defer { store._test_providerRefreshOverride = nil }

        store.switchClaudeSwapAccount(accountID)
        let task = try #require(store.claudeSwapTransientState.task)
        await task.value

        let arguments = try String(contentsOf: marker, encoding: .utf8)
        #expect(arguments == "--switch-to\n2\n--json\n")
        #expect(refreshedProviders == [.claude])
        #expect(store.claudeSwapTransientState.task == nil)
        #expect(store.claudeSwapTransientState.switchingAccountID == nil)
        #expect(store.claudeSwapTransientState.lastError == nil)
        #expect(store.claudeSwapTransientState.lastErrorAccountID == nil)
    }

    @Test
    func `non actionable account cannot start credential transaction`() throws {
        let (settings, store) = self.makeStore()
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        settings.claudeSwapExecutablePath = "/path/to/cswap"
        settings.claudeSwapEnabled = true
        let accountID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2")
        store.claudeSwapAccountSnapshots = [ProviderAccountUsageSnapshot(
            id: accountID,
            provider: .claude,
            displayLabel: "expired@example.com",
            isActive: false,
            canActivate: false,
            snapshot: nil,
            error: "Token expired",
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)]

        store.switchClaudeSwapAccount(accountID)

        #expect(store.claudeSwapTransientState.task == nil)
    }

    @Test
    func `failed activation stays scoped to its requested account`() async throws {
        let (settings, store) = self.makeStore()
        let executable = try self.makeFailedSwitchExecutable()
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        settings.claudeSwapExecutablePath = executable
        settings.claudeSwapEnabled = true
        let accountID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2")
        store.claudeSwapAccountSnapshots = [ProviderAccountUsageSnapshot(
            id: accountID,
            provider: .claude,
            displayLabel: "switch@example.com",
            isActive: false,
            canActivate: true,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)]
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }

        store.switchClaudeSwapAccount(accountID)
        let task = try #require(store.claudeSwapTransientState.task)
        await task.value

        #expect(store.claudeSwapTransientState.lastError?.contains("credentials missing") == true)
        #expect(store.claudeSwapTransientState.lastErrorAccountID == accountID)
    }

    @Test
    func `configuration change during provider refresh discards switch result`() async throws {
        let (settings, store) = self.makeStore()
        let executable = try self.makeFailedSwitchExecutable()
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        settings.claudeSwapExecutablePath = executable
        settings.claudeSwapEnabled = true
        let accountID = ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2")
        store.claudeSwapAccountSnapshots = [ProviderAccountUsageSnapshot(
            id: accountID,
            provider: .claude,
            displayLabel: "switch@example.com",
            isActive: false,
            canActivate: true,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)]
        store._test_providerRefreshOverride = { _ in
            settings.claudeSwapExecutablePath = "/new/path/to/cswap"
        }
        defer { store._test_providerRefreshOverride = nil }

        store.switchClaudeSwapAccount(accountID)
        let task = try #require(store.claudeSwapTransientState.task)
        await task.value

        #expect(store.claudeSwapTransientState.task == nil)
        #expect(store.claudeSwapTransientState.switchingAccountID == nil)
        #expect(store.claudeSwapTransientState.lastError == nil)
        #expect(store.claudeSwapTransientState.lastErrorAccountID == nil)
    }

    private func makeStore() -> (SettingsStore, UsageStore) {
        let suite = "ClaudeProviderRuntimeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        return (settings, store)
    }

    private func accountSnapshot() -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "1"),
            provider: .claude,
            displayLabel: "account@example.com",
            isActive: false,
            snapshot: nil,
            error: "Token expired",
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
    }

    private func makeFakeExecutable() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cswap")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'cswap 0.16.0'
          exit 0
        fi
        sleep 0.3
        cat <<'EOF'
        {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
          {"number":1,"email":"a@b.c","active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":12.5}}}
        ]}
        EOF
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeSwitchExecutable(marker: URL) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-switch-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cswap")
        let script = """
        #!/bin/sh
        printf '%s\n' "$@" > '\(marker.path)'
        echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"switched"}'
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeFailedSwitchExecutable() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-failed-switch-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cswap")
        let script = """
        #!/bin/sh
        echo '{"schemaVersion":1,"error":{"type":"SwitchError","message":"credentials missing"}}'
        exit 1
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
