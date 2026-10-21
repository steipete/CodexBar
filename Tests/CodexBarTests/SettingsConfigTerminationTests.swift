import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsConfigTerminationTests {
    @Test
    func `failed physical save preserves a repair until full reload`() async throws {
        try await self.withSettings { settings in
            settings.configFileWatcher?.stop()
            settings[providerConfig: .fireworks, field: .apiKey] = "fixture-key"
            try #require(await settings.savePluginSettings(
                provider: .fireworks,
                values: ["ACCOUNT_SLUG": "fixture"],
                isCurrent: { true }) == .saved)
            let corrupt = Data("synthetic-corrupt-config".utf8)
            try corrupt.write(to: settings.configStore.fileURL)
            settings.opencodeWorkspaceID = "edit-during-corruption"
            await self.drainSaves(settings)
            #expect(try Data(contentsOf: settings.configStore.fileURL) == corrupt)

            var repaired = settings.configSnapshot
            var entry = try #require(repaired.providerConfig(for: .opencode))
            entry.workspaceID = "manually-repaired-workspace"
            repaired.setProviderConfig(entry)
            let expected = try settings.configStore.encodedData(for: repaired)
            try expected.write(to: settings.configStore.fileURL, options: .atomic)
            #expect(await settings.savePluginSettings(
                provider: .fireworks,
                values: ["ACCOUNT_SLUG": "fixture"],
                isCurrent: { true }) == .unchanged)
            settings.opencodeWorkspaceID = "stale-edit-before-reload"
            await self.drainSaves(settings)
            #expect(try Data(contentsOf: settings.configStore.fileURL) == expected)

            settings.reloadConfig(reason: "physical-save-repair", origin: .localFile)
            settings.opencodeWorkspaceID = "edit-after-reload"
            await self.drainSaves(settings)
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID == "edit-after-reload")
        }
    }

    @Test
    func `account reload preserves the rest of the externally edited config`() async throws {
        try await self.withSettings { settings in
            settings.configFileWatcher?.stop()
            var edited = settings.configSnapshot
            var entry = try #require(edited.providerConfig(for: .opencode))
            entry.workspaceID = "externally-edited-workspace"
            edited.setProviderConfig(entry)
            try settings.configStore.save(edited)

            settings.reloadTokenAccounts()
            await self.drainSaves(settings)

            #expect(settings.opencodeWorkspaceID == "externally-edited-workspace")
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID
                == "externally-edited-workspace")
        }
    }

    @Test(arguments: [false, true])
    func `failed secondary config reads preserve a repair until full reload`(_ pluginSave: Bool) async throws {
        try await self.withSettings { settings in
            settings.configFileWatcher?.stop()
            if pluginSave {
                settings[providerConfig: .fireworks, field: .apiKey] = "fixture-key"
                try #require(await settings.savePluginSettings(
                    provider: .fireworks,
                    values: ["ACCOUNT_SLUG": "fixture"],
                    isCurrent: { true }) == .saved)
            }
            try Data("synthetic-corrupt-config".utf8).write(to: settings.configStore.fileURL)
            if pluginSave {
                #expect(await settings.savePluginSettings(
                    provider: .fireworks,
                    values: ["ACCOUNT_SLUG": "updated-fixture"],
                    isCurrent: { true }) == .failed)
            } else {
                settings.reloadTokenAccounts()
            }

            var repaired = settings.configSnapshot
            var entry = try #require(repaired.providerConfig(for: .opencode))
            entry.workspaceID = "manually-repaired-workspace"
            repaired.setProviderConfig(entry)
            let expected = try settings.configStore.encodedData(for: repaired)
            try expected.write(to: settings.configStore.fileURL, options: .atomic)
            settings.opencodeWorkspaceID = "stale-edit-before-reload"
            await self.drainSaves(settings)
            #expect(try Data(contentsOf: settings.configStore.fileURL) == expected)

            settings.reloadConfig(reason: "secondary-read-repair", origin: .localFile)
            settings.opencodeWorkspaceID = "edit-after-reload"
            await self.drainSaves(settings)
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID == "edit-after-reload")
        }
    }

    @Test(arguments: [false, true])
    func `failed reload invalidates a physical writer even after repair`(_ repairImmediately: Bool) async throws {
        let fileManager = PausingConfigFileManager()
        try await self.withSettings(fileManager: fileManager) { settings in
            settings.configFileWatcher?.stop()
            fileManager.pauseNextWrite()
            defer { fileManager.releaseWriter() }
            settings.opencodeWorkspaceID = "stale-pending-edit"
            try await self.waitUntil { fileManager.writerIsPaused }
            let physicalWrite = try #require(settings.configPersistWriteTask)
            let corrupt = Data("synthetic-runtime-corruption".utf8)
            try corrupt.write(to: settings.configStore.fileURL)
            settings.reloadConfig(reason: "physical-writer-regression")
            var expected = corrupt
            if repairImmediately {
                var repair = settings.configSnapshot
                var entry = try #require(repair.providerConfig(for: .opencode))
                entry.workspaceID = "manually-repaired"
                repair.setProviderConfig(entry)
                expected = try settings.configStore.encodedData(for: repair)
                try expected.write(to: settings.configStore.fileURL, options: .atomic)
                settings.reloadConfig(reason: "manual-repair")
            }
            fileManager.releaseWriter()
            await physicalWrite.value
            #expect(try Data(contentsOf: settings.configStore.fileURL) == expected)
        }
    }

    @Test
    func `quit preserves a provider toggle before its debounce expires`() async throws {
        try await self.withSettings { settings in
            let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
            #expect(try settings.configStore.load()?.providerConfig(for: .claude)?.enabled == false)

            let approved = try await self.configAtTerminationApproval(settings)

            #expect(approved.providerConfig(for: .claude)?.enabled == true)
        }
    }

    @Test
    func `quit persists the latest coalesced workspace edit`() async throws {
        try await self.withSettings { settings in
            settings.opencodeWorkspaceID = "wrk_first"
            settings.opencodeWorkspaceID = "  wrk_latest  "
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID == nil)

            let approved = try await self.configAtTerminationApproval(settings)

            #expect(approved.providerConfig(for: .opencode)?.workspaceID == "wrk_latest")
        }
    }

    @Test
    func `normal debounce persists settings without a quit request`() async throws {
        try await self.withSettings { settings in
            settings.opencodeWorkspaceID = "wrk_normal"
            let before = try settings.configStore.load()
            #expect(before?.providerConfig(for: .opencode)?.workspaceID == nil)

            await self.drainSaves(settings)

            let after = try settings.configStore.load()
            #expect(after?.providerConfig(for: .opencode)?.workspaceID == "wrk_normal")
        }
    }

    @Test
    func `quit without pending edits does not overwrite an external config change`() async throws {
        try await self.withSettings { settings in
            // Also cover an already-finished save: a completed task must not make the in-memory
            // snapshot authoritative over a later external edit.
            settings.opencodeWorkspaceID = "wrk_finished"
            await self.drainSaves(settings)
            var external = settings.configSnapshot
            var provider = try #require(external.providerConfig(for: .opencode))
            provider.workspaceID = "wrk_external"
            external.setProviderConfig(provider)
            try settings.configStore.save(external)
            let delegate = self.makeDelegate(settings)
            var receivedReply = false
            delegate.replyToApplicationShouldTerminate = { _, _ in receivedReply = true }

            let response = (delegate as NSApplicationDelegate)
                .applicationShouldTerminate?(NSApplication.shared) ?? .terminateNow

            #expect(response == .terminateNow)
            #expect(!receivedReply)
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID == "wrk_external")
        }
    }

    @Test
    func `quit waits for an in flight writer before saving its replacement`() async throws {
        let fileManager = PausingConfigFileManager()
        try await self.withSettings(fileManager: fileManager) { settings in
            fileManager.pauseNextWrite()
            defer { fileManager.releaseWriter() }
            settings.opencodeWorkspaceID = "wrk_older"
            try await self.waitUntil { fileManager.writerIsPaused }
            settings.opencodeWorkspaceID = "wrk_replacement"
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID == nil)
            // Release from a separate queue so this also permits a synchronous termination barrier.
            fileManager.releaseWriterSoon()

            let approved = try await self.configAtTerminationApproval(settings)

            #expect(approved.providerConfig(for: .opencode)?.workspaceID == "wrk_replacement")
            await self.drainSaves(settings)
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID == "wrk_replacement")
        }
    }

    @Test
    func `repeated quit requests share one pending save and reply`() async throws {
        let fileManager = PausingConfigFileManager()
        try await self.withSettings(fileManager: fileManager) { settings in
            fileManager.pauseNextWrite()
            defer { fileManager.releaseWriter() }
            settings.opencodeWorkspaceID = "wrk_older"
            try await self.waitUntil { fileManager.writerIsPaused }
            settings.opencodeWorkspaceID = "wrk_latest"
            let delegate = self.makeDelegate(settings)
            var replies = 0
            delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
                #expect(shouldTerminate)
                replies += 1
            }
            let first = (delegate as NSApplicationDelegate)
                .applicationShouldTerminate?(NSApplication.shared) ?? .terminateNow
            let second = (delegate as NSApplicationDelegate)
                .applicationShouldTerminate?(NSApplication.shared) ?? .terminateNow
            #expect(!fileManager.writerFinishedWaiting)
            #expect(replies == 0)
            fileManager.releaseWriter()
            try #require(first == .terminateLater)
            #expect(second == .terminateLater)
            try await self.waitUntil { replies > 0 }
            await self.drainSaves(settings)
            self.deliverTerminationReplies()
            #expect(replies == 1)
            #expect(try settings.configStore.load()?.providerConfig(for: .opencode)?.workspaceID == "wrk_latest")
        }
    }

    @Test
    func `a failed final write still resolves the quit request`() async throws {
        try await self.withSettings { settings in
            settings.opencodeWorkspaceID = "wrk_pending"
            let url = settings.configStore.fileURL
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let delegate = self.makeDelegate(settings)
            var approved = false
            delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
                approved = shouldTerminate
            }
            let response = (delegate as NSApplicationDelegate)
                .applicationShouldTerminate?(NSApplication.shared) ?? .terminateNow
            if response == .terminateNow { approved = true }
            try await self.waitUntil { approved }
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    private func makeDelegate(_ settings: SettingsStore) -> AppDelegate {
        let delegate = AppDelegate()
        // Avoid configure's unrelated CloudSyncPersistence reads and lazy UI dependencies.
        delegate._test_configureSettings(settings)
        return delegate
    }

    private func configAtTerminationApproval(_ settings: SettingsStore) async throws -> CodexBarConfig {
        let delegate = self.makeDelegate(settings)
        var approved = false
        var diskConfig: CodexBarConfig?
        delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
            #expect(shouldTerminate)
            diskConfig = try? settings.configStore.load()
            approved = true
        }
        // The optional protocol call also works on the original implementation, whose absent
        // delegate method permits immediate termination. Never ask NSApplication to terminate.
        let response = (delegate as NSApplicationDelegate)
            .applicationShouldTerminate?(NSApplication.shared) ?? .terminateNow
        if response == .terminateNow {
            diskConfig = try settings.configStore.load()
            approved = true
        } else {
            #expect(response == .terminateLater)
        }
        try await self.waitUntil { approved }
        return try #require(diskConfig)
    }

    private func withSettings(
        fileManager: FileManager? = nil,
        _ operation: (SettingsStore) async throws -> Void) async throws
    {
        let settings: SettingsStore
        if let fileManager {
            let fixture = testConfigStore(suiteName: "SettingsConfigTerminationTests-\(UUID().uuidString)")
            let configStore = CodexBarConfigStore(fileURL: fixture.fileURL, fileManager: fileManager)
            try configStore.save(testConfigWithAllProvidersDisabled())
            settings = SettingsStore(
                userDefaults: InMemoryUserDefaults(),
                configStore: configStore,
                zaiTokenStore: NoopZaiTokenStore(),
                syntheticTokenStore: NoopSyntheticTokenStore(),
                tokenAccountStore: InMemoryTokenAccountStore(),
                keychainAccessPolicy: SettingsStoreKeychainAccessPolicy(
                    setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        } else {
            settings = testSettingsStore(
                suiteName: "SettingsConfigTerminationTests",
                userDefaults: InMemoryUserDefaults(),
                config: testConfigWithAllProvidersDisabled())
        }
        settings._test_configPersistenceUsesDebounce = true
        defer { try? FileManager.default.removeItem(at: settings.configStore.fileURL.deletingLastPathComponent()) }
        do {
            try await operation(settings)
        } catch {
            await self.drainSaves(settings)
            throw error
        }
        await self.drainSaves(settings)
    }

    private func drainSaves(_ settings: SettingsStore) async {
        while let pending = settings.configPersistTask {
            await pending.value
            if settings.configPersistTask == pending { break }
        }
    }

    private func deliverTerminationReplies() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() {
            self.deliverTerminationReplies()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class PausingConfigFileManager: FileManager {
    private let lock = NSLock()
    private let resumeWriter = DispatchSemaphore(value: 0)
    private var pauseRequested = false
    private var paused = false
    private var finishedWaiting = false

    var writerIsPaused: Bool {
        self.lock.withLock { self.paused }
    }

    var writerFinishedWaiting: Bool {
        self.lock.withLock { self.finishedWaiting }
    }

    func pauseNextWrite() {
        self.lock.withLock {
            self.pauseRequested = true
            self.finishedWaiting = false
        }
    }

    func releaseWriter() {
        self.resumeWriter.signal()
    }

    func releaseWriterSoon() {
        let semaphore = self.resumeWriter
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            semaphore.signal()
        }
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil) throws
    {
        let shouldPause = self.lock.withLock {
            guard self.pauseRequested else { return false }
            self.pauseRequested = false
            self.paused = true
            return true
        }
        if shouldPause {
            self.resumeWriter.wait()
            self.lock.withLock { self.finishedWaiting = true }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
