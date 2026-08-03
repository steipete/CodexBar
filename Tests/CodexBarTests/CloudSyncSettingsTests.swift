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

        store.applySyncedPreferences(remote)

        #expect(!store.statusChecksEnabled)
        #expect(store.usageBarsShowUsed)
        #expect(store.costUsageEnabled)
        #expect(store.preferredCurrencyCode == "EUR")
        #expect(store.refreshFrequency == .thirtyMinutes)
        #expect(store.debugMenuEnabled)
        #expect(store.iCloudSyncEnabled)
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
