import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsConfigTerminationTests {
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
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            self.deliverTerminationReplies()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

private final class PausingConfigFileManager: FileManager {
    private let lock = NSLock()
    private let resumeWriter = DispatchSemaphore(value: 0)
    private var pauseRequested = false
    private var paused = false

    var writerIsPaused: Bool {
        self.lock.withLock { self.paused }
    }

    func pauseNextWrite() {
        self.lock.withLock { self.pauseRequested = true }
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
            guard self.resumeWriter.wait(timeout: .now() + 5) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
