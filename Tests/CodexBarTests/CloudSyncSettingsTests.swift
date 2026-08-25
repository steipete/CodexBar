import CloudKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CloudSyncSettingsTests {
    @Test
    func `sync settings use strict opt in defaults and stay local`() throws {
        let fixture = try self.makeFixture("local-defaults")
        let store = fixture.store

        #expect(!store.iCloudSyncEnabled)
        #expect(store.iCloudSyncIncludeSecrets)
        #expect(store.iCloudSyncSnapshotsEnabled)
        #expect(store.iCloudSyncShowFleetAccounts)
        #expect(UUID(uuidString: store.iCloudSyncDeviceID) != nil)

        store.iCloudSyncEnabled = true
        store.iCloudSyncIncludeSecrets = false
        #expect(fixture.defaults.bool(forKey: "iCloudSyncEnabled"))
        #expect(!fixture.defaults.bool(forKey: "iCloudSyncIncludeSecrets"))
    }

    @Test
    func `preferences subset applies through settings without touching excluded keys`() throws {
        let fixture = try self.makeFixture("preferences")
        let store = fixture.store
        store.debugMenuEnabled = true
        store.iCloudSyncEnabled = true
        var remote = store.syncedPreferences
        remote.statusChecksEnabled = false
        remote.usageBarsShowUsed = true
        remote.costUsageEnabled = true
        remote.preferredCurrencyCode = "EUR"
        remote.refreshFrequency = RefreshFrequency.thirtyMinutes.rawValue
        remote.workdayTickAppearance = WorkdayTickAppearance.highContrast.rawValue

        store.applySyncedPreferences(remote)

        #expect(!store.statusChecksEnabled)
        #expect(store.usageBarsShowUsed)
        #expect(store.costUsageEnabled)
        #expect(store.preferredCurrencyCode == "EUR")
        #expect(store.refreshFrequency == .thirtyMinutes)
        #expect(store.workdayTickAppearance == .highContrast)
        #expect(store.debugMenuEnabled)
        #expect(store.iCloudSyncEnabled)
    }

    @Test
    func `legacy synced preferences without workday appearance decode compatibly`() throws {
        let fixture = try self.makeFixture("legacy-workday-appearance")
        let payload = PreferencesSyncPayload(preferences: fixture.store.syncedPreferences)
        let encoded = try CanonicalSyncJSON.encode(payload)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var preferences = try #require(object["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "workdayTickAppearance")
        object["preferences"] = preferences
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try CanonicalSyncJSON.decode(PreferencesSyncPayload.self, from: legacyData)

        #expect(decoded.preferences.workdayTickAppearance == nil)
    }

    @Test
    func `legacy synced preferences without pace visibility decode compatibly`() throws {
        let fixture = try self.makeFixture("legacy-pace-visible")
        let payload = PreferencesSyncPayload(preferences: fixture.store.syncedPreferences)
        let encoded = try CanonicalSyncJSON.encode(payload)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var preferences = try #require(object["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "paceVisible")
        object["preferences"] = preferences
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try CanonicalSyncJSON.decode(PreferencesSyncPayload.self, from: legacyData)

        #expect(decoded.preferences.paceVisible == nil)

        // An absent key must leave the local value untouched, not reset it.
        fixture.store.paceVisible = false
        fixture.store.applySyncedPreferences(decoded.preferences)
        #expect(fixture.store.paceVisible == false)
    }

    @Test
    func `config watcher suppresses self writes and observes external atomic replacement`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigFileWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = Data("{\"value\":1}".utf8)
        try original.write(to: url, options: .atomic)
        let changes = LockedCounter()
        let watcher = ConfigFileWatcher(fileURL: url) { changes.increment() }
        watcher.start()
        try await Task.sleep(for: .milliseconds(150))

        let ownWrite = Data("{\"value\":2}".utf8)
        watcher.noteAppWrite(data: ownWrite)
        try ownWrite.write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(350))
        #expect(changes.value == 0)

        try Data("{\"value\":3}".utf8).write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        watcher.stop()
        #expect(changes.value >= 1)
    }

    @Test
    func `sync persistence never writes encrypted provider secrets and uses private permissions`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("engine-state.json")
        let persistence = CloudSyncPersistence(fileURL: fileURL)
        let config = ProviderConfig(id: .openai, apiKey: "SENTINEL-SECRET")
        let recordID = CKRecord.ID(
            recordName: ProviderIntentPayload.recordName(for: config.id),
            zoneID: CloudSyncEngine.zoneID)
        let record = CKRecord(recordType: SyncRecordType.providerIntent.rawValue, recordID: recordID)
        record["payload"] = try CanonicalSyncJSON.string(ProviderIntentPayload(config: config)) as CKRecordValue
        record.encryptedValues[ProviderIntentSecretField.apiKey.rawValue] = config.apiKey as CKRecordValue?

        var envelope = CloudSyncPersistence.Envelope(stateSerialization: nil, encodedSystemFields: [:])
        CloudSyncPersistence.cacheSystemFields(of: record, in: &envelope)
        try persistence.save(envelope)
        let loaded = persistence.load()
        let bytes = try Data(contentsOf: fileURL)
        let contents = try #require(String(bytes: bytes, encoding: .utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        #expect(!contents.contains("SENTINEL-SECRET"))
        #expect(loaded.encodedSystemFields[recordID.recordName] != nil)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func `legacy sync persistence defaults dirty state to clean`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncPersistenceLegacyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("engine-state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {
          "encodedSystemFields": {},
          "recordMetadata": {},
          "suppressedEnableIntents": [],
          "fleetDevices": {},
          "fleetSnapshots": {}
        }
        """.utf8).write(to: fileURL)

        let envelope = CloudSyncPersistence(fileURL: fileURL).load()

        #expect(envelope.dirtyProviders.isEmpty)
        #expect(!envelope.preferencesDirty)
        #expect(envelope.pendingSnapshotDeletes.isEmpty)
    }

    @Test
    func `pending snapshot deletes survive persistence round trip`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncPendingDeletesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("engine-state.json")
        let persistence = CloudSyncPersistence(fileURL: fileURL)
        var envelope = CloudSyncPersistence.Envelope(stateSerialization: nil, encodedSystemFields: [:])
        envelope.pendingSnapshotDeletes = ["snap-claude-old-device-id"]
        try persistence.save(envelope)

        #expect(persistence.load().pendingSnapshotDeletes == ["snap-claude-old-device-id"])
    }

    @Test
    func `pending predecessor deletes survive persistence round trip`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncPendingPredecessorsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("engine-state.json")
        let persistence = CloudSyncPersistence(fileURL: fileURL)
        var envelope = CloudSyncPersistence.Envelope(stateSerialization: nil, encodedSystemFields: [:])
        envelope.pendingPredecessorDeletes = ["snap-claude-slot-device-id": ["snap-claude-old-device-id"]]
        try persistence.save(envelope)

        #expect(
            persistence.load().pendingPredecessorDeletes["snap-claude-slot-device-id"] == [
                "snap-claude-old-device-id",
            ])
    }

    @Test
    func `relaunch with cached fleet records and clean dirty set queues no configuration records`() {
        let metadata = CloudSyncPersistence.RecordMetadata(
            recordType: SyncRecordType.providerIntent.rawValue,
            schemaVersion: CodexBarSyncSchema.currentVersion,
            editCount: 4,
            modifiedAt: Date())
        let envelope = CloudSyncPersistence.Envelope(
            stateSerialization: nil,
            encodedSystemFields: [:],
            recordMetadata: [ProviderIntentPayload.recordName(for: .claude): metadata])

        let recordNames = CloudSyncDirtyState.configurationRecordNamesToQueue(
            envelope: envelope,
            configuredProviders: [.claude, .codex])

        #expect(recordNames.isEmpty)
    }

    @Test
    func `local provider edit queues exactly that provider`() async throws {
        let fixture = try self.makeFixture("dirty-provider")
        let persistence = self.makePersistence("dirty-provider")
        let initial = fixture.store.configSnapshot
        let engine = CloudSyncEngine(
            settings: fixture.store,
            state: CloudSyncState(),
            persistence: persistence,
            initialConfiguration: initial,
            initialPreferences: fixture.store.syncedPreferences,
            initialIncludeSecrets: fixture.store.iCloudSyncIncludeSecrets)
        var updated = initial
        var claude = try #require(updated.providerConfig(for: .claude))
        claude.extrasEnabled = !(claude.extrasEnabled ?? false)
        updated.setProviderConfig(claude)

        await engine.localUserConfigurationDidChange(updated)

        let envelope = persistence.load()
        let recordNames = CloudSyncDirtyState.configurationRecordNamesToQueue(
            envelope: envelope,
            configuredProviders: updated.providers.map(\.id))
        #expect(recordNames == [ProviderIntentPayload.recordName(for: .claude)])
    }

    @Test
    func `CLI style file edit queues exactly that provider`() async throws {
        let fixture = try self.makeFixture("dirty-file-provider")
        let persistence = self.makePersistence("dirty-file-provider")
        let coordinator = CloudSyncCoordinator(settings: fixture.store, persistence: persistence)
        coordinator.start()
        defer { coordinator.stop() }
        try fixture.store.configStore.save(fixture.store.configSnapshot)
        try await Task.sleep(for: .milliseconds(500))

        var updated = fixture.store.configSnapshot
        var claude = try #require(updated.providerConfig(for: .claude))
        claude.extrasEnabled = !(claude.extrasEnabled ?? false)
        updated.setProviderConfig(claude)
        try fixture.store.configStore.save(updated)

        for _ in 0..<100 where persistence.load().dirtyProviders.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let envelope = persistence.load()
        let recordNames = CloudSyncDirtyState.configurationRecordNamesToQueue(
            envelope: envelope,
            configuredProviders: updated.providers.map(\.id))
        #expect(recordNames == [ProviderIntentPayload.recordName(for: .claude)])
    }

    @Test
    func `machine local provider edit does not become dirty`() async throws {
        let fixture = try self.makeFixture("machine-local-provider")
        let persistence = self.makePersistence("machine-local-provider")
        let initial = fixture.store.configSnapshot
        let engine = CloudSyncEngine(
            settings: fixture.store,
            state: CloudSyncState(),
            persistence: persistence,
            initialConfiguration: initial,
            initialPreferences: fixture.store.syncedPreferences,
            initialIncludeSecrets: fixture.store.iCloudSyncIncludeSecrets)
        var updated = initial
        var claude = try #require(updated.providerConfig(for: .claude))
        claude.claudeSwapExecutablePath = "/machine-only/claude-swap"
        updated.setProviderConfig(claude)

        await engine.localUserConfigurationDidChange(updated)

        #expect(persistence.load().dirtyProviders.isEmpty)
    }

    @Test
    func `empty fleet bootstrap dirties every configured provider and preferences`() {
        var envelope = CloudSyncPersistence.Envelope(stateSerialization: nil, encodedSystemFields: [:])

        CloudSyncDirtyState.markBootstrapDirtyIfNeeded(
            configuredProviders: [.claude, .codex],
            envelope: &envelope)

        #expect(envelope.dirtyProviders == [UsageProvider.claude.rawValue, UsageProvider.codex.rawValue])
        #expect(envelope.preferencesDirty)
    }

    @Test
    func `successful saves clear dirty while failed saves keep it`() {
        var envelope = CloudSyncPersistence.Envelope(
            stateSerialization: nil,
            encodedSystemFields: [:],
            dirtyProviders: [UsageProvider.claude.rawValue, UsageProvider.codex.rawValue],
            preferencesDirty: true)

        CloudSyncDirtyState.clearSavedRecords(
            [ProviderIntentPayload.recordName(for: .claude), PreferencesSyncPayload.recordName],
            envelope: &envelope)

        #expect(envelope.dirtyProviders == [UsageProvider.codex.rawValue])
        #expect(!envelope.preferencesDirty)
        #expect(envelope.dirtyProviders.contains(UsageProvider.codex.rawValue))
    }

    @Test
    func `remote provider apply writes config without becoming dirty`() async throws {
        let fixture = try self.makeFixture("remote-provider")
        let persistence = self.makePersistence("remote-provider")
        let initial = fixture.store.configSnapshot
        let coordinator = CloudSyncCoordinator(settings: fixture.store, persistence: persistence)
        coordinator.start()
        defer { coordinator.stop() }
        try fixture.store.configStore.save(initial)
        try await Task.sleep(for: .milliseconds(500))
        let engine = CloudSyncEngine(
            settings: fixture.store,
            state: CloudSyncState(),
            persistence: persistence,
            initialConfiguration: initial,
            initialPreferences: fixture.store.syncedPreferences,
            initialIncludeSecrets: fixture.store.iCloudSyncIncludeSecrets)
        var remoteConfig = try #require(initial.providerConfig(for: .claude))
        remoteConfig.extrasEnabled = !(remoteConfig.extrasEnabled ?? false)
        let recordID = CKRecord.ID(
            recordName: ProviderIntentPayload.recordName(for: .claude),
            zoneID: CloudSyncEngine.zoneID)
        let record = CKRecord(recordType: SyncRecordType.providerIntent.rawValue, recordID: recordID)
        record["payload"] = try CanonicalSyncJSON.string(ProviderIntentPayload(config: remoteConfig)) as CKRecordValue

        await engine.applyFetchedRecords([record])
        try await Task.sleep(for: .milliseconds(500))

        let savedConfig = try #require(try fixture.store.configStore.load())
        #expect(savedConfig.providerConfig(for: .claude)?.extrasEnabled == remoteConfig.extrasEnabled)
        #expect(persistence.load().dirtyProviders.isEmpty)
    }

    @Test
    func `missing desired record drains its pending save`() {
        let recordID = CKRecord.ID(recordName: "stale", zoneID: CloudSyncEngine.zoneID)
        let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)
        var pending: Set<CKSyncEngine.PendingRecordZoneChange> = [change]

        let record = CloudSyncBatchRecordProvider.record(for: recordID, desiredRecords: [:]) {
            pending.remove($0)
        }

        #expect(record == nil)
        #expect(pending.isEmpty)
    }

    @Test
    func `quota backoff doubles to one hour and resets after success`() {
        var backoff = CloudSyncQuotaRetryState()

        #expect(backoff.nextDelay(serverRetryAfter: 120) == 120)
        #expect(backoff.nextDelay(serverRetryAfter: 999) == 240)
        #expect(backoff.nextDelay(serverRetryAfter: nil) == 480)
        for _ in 0..<10 {
            _ = backoff.nextDelay(serverRetryAfter: nil)
        }
        #expect(backoff.nextDelay(serverRetryAfter: nil) == 3600)

        backoff.reset()
        #expect(backoff.nextDelay(serverRetryAfter: 30) == 30)
    }

    @Test
    func `delegate events leave callback context before engine work and stay ordered`() async {
        let queue = CloudSyncDelegateEventQueue()
        let recorder = CloudSyncDelegateEventRecorder()

        let inheritedCallbackContext = await withCheckedContinuation { continuation in
            CloudSyncDelegateCallbackContext.$isActive.withValue(true) {
                queue.enqueue {
                    continuation.resume(returning: CloudSyncDelegateCallbackContext.isActive)
                }
            }
        }

        #expect(!inheritedCallbackContext)

        await withCheckedContinuation { continuation in
            queue.enqueue {
                try? await Task.sleep(for: .milliseconds(50))
                await recorder.append(1)
            }
            queue.enqueue {
                await recorder.append(2)
                continuation.resume()
            }
        }

        #expect(await recorder.values == [1, 2])
    }

    private func makeFixture(_ name: String) throws -> (store: SettingsStore, defaults: UserDefaults) {
        let suite = "CloudSyncSettingsTests-\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let configStore = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            performInitialProviderDetection: false)
        return (store, defaults)
    }

    private func makePersistence(_ name: String) -> CloudSyncPersistence {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncDirtyTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        return CloudSyncPersistence(fileURL: directory.appendingPathComponent("engine-state.json"))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        self.lock.withLock { self.storage }
    }

    func increment() {
        self.lock.withLock { self.storage += 1 }
    }
}

private enum CloudSyncDelegateCallbackContext {
    @TaskLocal static var isActive = false
}

private actor CloudSyncDelegateEventRecorder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        self.values.append(value)
    }
}
