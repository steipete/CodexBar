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
}
