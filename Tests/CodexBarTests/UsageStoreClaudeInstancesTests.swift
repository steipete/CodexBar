import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreClaudeInstancesTests {
    private static let work = ClaudeInstanceConfig(id: "work", name: "Work", configDirectory: "/tmp/claude-work")
    private static let personal = ClaudeInstanceConfig(
        id: "personal",
        name: "Personal",
        configDirectory: "/tmp/claude-personal")

    @Test
    func `instances refresh one at a time and publish cards in configured order`() async throws {
        let (settings, store) = try self.makeStore()
        let recorder = LoadRecorder()
        store.claudeInstanceUsageLoaderOverride = { instance in
            try await recorder.load(instance.id)
        }
        try await self.configure(settings: settings, store: store, recorder: recorder)

        await store.refreshClaudeInstances()

        #expect(store.claudeInstanceAccountSnapshots.map(\.displayLabel) == ["Work", "Personal"])
        #expect(await recorder.order == ["work", "personal"])
        #expect(await recorder.maxConcurrent == 1)
        #expect(store.claudeInstancesOwnAccountPresentation)
        #expect(store.menuBarSnapshot(for: UsageProvider.claude.instanceID)?.primary?.usedPercent == 10)
    }

    @Test
    func `failed instance refresh keeps its last usage beside the error`() async throws {
        let (settings, store) = try self.makeStore()
        let recorder = LoadRecorder()
        store.claudeInstanceUsageLoaderOverride = { instance in
            try await recorder.load(instance.id)
        }
        try await self.configure(settings: settings, store: store, recorder: recorder)
        await store.refreshClaudeInstances()

        store.claudeInstanceUsageLoaderOverride = { instance in
            if instance.id == "personal" {
                throw ClaudeInstanceTestError()
            }
            return try await recorder.load(instance.id)
        }
        await store.refreshClaudeInstances()

        let personal = try #require(store.claudeInstanceAccountSnapshots.last)
        #expect(personal.snapshot?.primary?.usedPercent == 20)
        #expect(personal.error?.hasPrefix("Showing the last successful update:") == true)
        #expect(store.claudeInstanceAccountSnapshots.first?.error == nil)
    }

    @Test
    func `results for an edited instance list are dropped`() async throws {
        let (settings, store) = try self.makeStore()
        let recorder = LoadRecorder()
        store.claudeInstanceUsageLoaderOverride = { instance in
            try await recorder.load(instance.id)
        }
        try await self.configure(settings: settings, store: store, recorder: recorder)
        store.claudeInstanceUsageLoaderOverride = { instance in
            await MainActor.run { settings.claudeInstances = [Self.personal] }
            return try await recorder.load(instance.id)
        }

        await store.refreshClaudeInstances()

        #expect(store.claudeInstanceAccountSnapshots.isEmpty)
    }

    @Test
    func `claude-swap and Claude instances cannot both be enabled`() throws {
        let (settings, _) = try self.makeStore()

        settings.claudeSwapEnabled = true
        settings.claudeInstancesEnabled = true
        #expect(settings.claudeInstancesEnabled)
        #expect(!settings.claudeSwapEnabled)

        settings.claudeSwapEnabled = true
        #expect(settings.claudeSwapEnabled)
        #expect(!settings.claudeInstancesEnabled)
    }

    @Test
    func `instance cards take precedence only for Claude`() {
        #expect(ClaudeSwapMenuPrecedence.prefersClaudeInstances(provider: .claude, instancesOwnPresentation: true))
        #expect(!ClaudeSwapMenuPrecedence.prefersClaudeInstances(provider: .claude, instancesOwnPresentation: false))
        #expect(!ClaudeSwapMenuPrecedence.prefersClaudeInstances(provider: .codex, instancesOwnPresentation: true))
    }

    @Test
    func `saving an instance draft normalizes paths and replaces the same instance in place`() throws {
        let (settings, _) = try self.makeStore()
        settings.claudeInstances = [Self.work, Self.personal]

        var draft = ClaudeInstanceDraft(instance: Self.work)
        draft.name = "  Work (renamed)  "
        draft.configDirectory = "~/.claude-work"
        draft.binaryPath = ""
        draft.environmentText = "HTTPS_PROXY=http://proxy.local:8080\nANTHROPIC_API_KEY=sk-ant-ignored"
        let instance = try #require(draft.makeInstance())
        settings.saveClaudeInstance(instance)

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(settings.claudeInstances.map(\.id) == ["work", "personal"])
        #expect(settings.claudeInstances.first?.name == "Work (renamed)")
        #expect(settings.claudeInstances.first?.configDirectory == "\(home)/.claude-work")
        #expect(settings.claudeInstances.first?.binaryPath == nil)
        #expect(settings.claudeInstances.first?.environment == ["HTTPS_PROXY": "http://proxy.local:8080"])

        settings.removeClaudeInstance(id: "work")
        #expect(settings.claudeInstances.map(\.id) == ["personal"])
    }

    @Test
    func `drafts with relative paths cannot be saved`() {
        var draft = ClaudeInstanceDraft.new()
        draft.configDirectory = "relative/profile"
        #expect(!draft.canSave)
        #expect(draft.makeInstance() == nil)

        draft.configDirectory = "/tmp/claude-work"
        draft.binaryPath = "bin/claude"
        #expect(!draft.canSave)

        draft.binaryPath = "/opt/claude/bin/claude"
        #expect(draft.canSave)
    }

    /// Enables instances, then cancels any refresh the settings change scheduled so each test drives its own.
    private func configure(settings: SettingsStore, store: UsageStore, recorder: LoadRecorder) async throws {
        settings.claudeInstances = [Self.work, Self.personal]
        settings.claudeInstancesEnabled = true
        let scheduled = store.claudeInstanceRefreshTask
        store.clearClaudeInstanceState()
        await scheduled?.value
        await recorder.reset()
    }

    private func makeStore() throws -> (SettingsStore, UsageStore) {
        let suite = "UsageStoreClaudeInstancesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        return (settings, store)
    }
}

private struct ClaudeInstanceTestError: LocalizedError {
    var errorDescription: String? {
        "Claude CLI is not logged in."
    }
}

private actor LoadRecorder {
    private(set) var order: [String] = []
    private(set) var maxConcurrent = 0
    private var running = 0

    func reset() {
        self.order = []
        self.maxConcurrent = 0
    }

    func load(_ id: String) async throws -> UsageSnapshot {
        self.running += 1
        self.maxConcurrent = max(self.maxConcurrent, self.running)
        self.order.append(id)
        defer { self.running -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: id == "work" ? 10 : 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }
}
