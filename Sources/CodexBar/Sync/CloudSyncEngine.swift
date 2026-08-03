import CloudKit
import CodexBarCore
import Foundation
import Observation
import Security

enum SyncAvailability: Equatable, Sendable {
    case available
    case missingEntitlement
    case noICloudAccount
    case restricted
}

struct SyncStatus: Equatable, Sendable {
    var needsAppUpdate = false
    var lastError: String?
    var lastSuccessfulFetchAt: Date?
    var lastSuccessfulPushAt: Date?
}

@MainActor
@Observable
final class CloudSyncState {
    var availability: SyncAvailability = .available
    var status = SyncStatus()
    var fleetDevices: [String: DeviceSyncPayload] = [:]
    var fleetSnapshots: [String: AccountSnapshotSyncPayload] = [:]
}

enum CloudSyncEntitlementGate {
    static let entitlement = "com.apple.developer.icloud-services"

    static func hasICloudServicesEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, self.entitlement as CFString, nil)
        else {
            return false
        }
        if let services = value as? [String] {
            return services.contains("CloudKit") || !services.isEmpty
        }
        return false
    }
}

actor CloudSyncEngine: CKSyncEngineDelegate {
    static let containerIdentifier = "iCloud.com.steipete.codexbar"
    static let zoneID = CKRecordZone.ID(zoneName: "CodexBarSync", ownerName: CKCurrentUserDefaultName)

    private let settings: SettingsStore
    private let state: CloudSyncState
    private let persistence: CloudSyncPersistence
    private var persistenceEnvelope: CloudSyncPersistence.Envelope
    private var engine: CKSyncEngine?
    private var desiredRecords: [CKRecord.ID: CKRecord] = [:]
    private var enabled = false
    private var configPushTask: Task<Void, Never>?
    private var snapshotPushTask: Task<Void, Never>?
    private var periodicFetchTask: Task<Void, Never>?
    private var lastSnapshotPushAt: Date?
    private var pendingSnapshots: [AccountSnapshotSyncPayload] = []
    private var lastSnapshotHashes: [String: String] = [:]
    private var lastQueuedConfigHash: String?
    private let logger = CodexBarLog.logger(LogCategories.settings)

    init(
        settings: SettingsStore,
        state: CloudSyncState,
        persistence: CloudSyncPersistence = CloudSyncPersistence())
    {
        self.settings = settings
        self.state = state
        self.persistence = persistence
        self.persistenceEnvelope = persistence.load()
    }

    func start(enabled: Bool) async {
        guard CloudSyncEntitlementGate.hasICloudServicesEntitlement() else {
            await self.updateAvailability(.missingEntitlement)
            return
        }
        await self.updateAvailability(.available)
        guard enabled else { return }
        await self.setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        guard enabled else {
            await self.stopEngine(clearPersistence: false)
            return
        }
        guard CloudSyncEntitlementGate.hasICloudServicesEntitlement() else {
            await self.updateAvailability(.missingEntitlement)
            return
        }
        do {
            try await self.initializeEngineIfNeeded()
            guard self.engine != nil else { return }
            try await self.queueCurrentConfigurationAndPreferences()
            guard await MainActor.run(body: { !self.state.status.needsAppUpdate }) else { return }
            try await self.queueDeviceRecord()
            self.startPeriodicFetchTimer()
            self.scheduleFetchChanges()
        } catch {
            await self.record(error: error)
        }
    }

    func scheduleConfigurationPush() {
        guard self.enabled, self.engine != nil else { return }
        self.configPushTask?.cancel()
        self.configPushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                try await self?.queueCurrentConfigurationAndPreferences()
            } catch is CancellationError {
                return
            } catch {
                await self?.record(error: error)
            }
        }
    }

    func queueSnapshots(_ snapshots: [AccountSnapshotSyncPayload]) async {
        guard self.enabled, self.engine != nil else { return }
        let options = await MainActor.run {
            (
                enabled: self.settings.iCloudSyncSnapshotsEnabled,
                lowPower: self.settings.backgroundWorkLowPowerModeEnabled
                    || ProcessInfo.processInfo.isLowPowerModeEnabled,
                needsAppUpdate: self.state.status.needsAppUpdate)
        }
        guard options.enabled, !options.lowPower, !options.needsAppUpdate else { return }
        self.pendingSnapshots = snapshots
        let elapsed = self.lastSnapshotPushAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed >= 120 {
            await self.pushPendingSnapshots()
            return
        }
        self.snapshotPushTask?.cancel()
        self.snapshotPushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(120 - elapsed))
                guard !Task.isCancelled else { return }
                await self?.pushPendingSnapshots()
            } catch {
                return
            }
        }
    }

    func fetchChanges() async {
        guard self.enabled, let engine = self.engine else { return }
        do {
            try await engine.fetchChanges(.init(scope: .zoneIDs([Self.zoneID])))
            await MainActor.run { self.state.status.lastSuccessfulFetchAt = Date() }
        } catch {
            await self.record(error: error)
        }
    }

    func stop() async {
        self.enabled = false
        await self.stopEngine(clearPersistence: false)
    }

    private func initializeEngineIfNeeded() async throws {
        guard self.engine == nil else { return }
        // This is the first CKContainer access, and every path here has already passed the entitlement gate.
        let container = CKContainer(identifier: Self.containerIdentifier)
        let accountStatus = try await container.accountStatus()
        switch accountStatus {
        case .available:
            await self.updateAvailability(.available)
        case .restricted:
            await self.updateAvailability(.restricted)
            return
        case .noAccount, .couldNotDetermine, .temporarilyUnavailable:
            await self.updateAvailability(.noICloudAccount)
            return
        @unknown default:
            await self.updateAvailability(.noICloudAccount)
            return
        }

        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: self.persistenceEnvelope.stateSerialization,
            delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
    }

    private func queueCurrentConfigurationAndPreferences() async throws {
        guard let engine = self.engine else { return }
        if self.persistenceEnvelope.recordFields.values.contains(where: {
            ($0.integers["schemaVersion"] ?? 0) > CodexBarSyncSchema.currentVersion
        }) {
            await MainActor.run { self.state.status.needsAppUpdate = true }
            return
        }
        let snapshot = await MainActor.run {
            (
                config: self.settings.configSnapshot,
                includeSecrets: self.settings.iCloudSyncIncludeSecrets,
                preferences: self.settings.syncedPreferences)
        }
        let configHash = try CanonicalSyncJSON.hash(data: snapshot.config.orderIndependentConfigData())
            + ":secrets=\(snapshot.includeSecrets)"
        if configHash != self.lastQueuedConfigHash {
            for config in snapshot.config.providers {
                try self.queueProviderIntent(config, includeSecrets: snapshot.includeSecrets, engine: engine)
            }
            self.lastQueuedConfigHash = configHash
        }
        try self.queuePreferences(snapshot.preferences, engine: engine)
    }

    private func queueProviderIntent(
        _ config: ProviderConfig,
        includeSecrets: Bool,
        engine: CKSyncEngine) throws
    {
        let payload = try CanonicalSyncJSON.string(ProviderIntentPayload(config: config))
        let recordID = self.recordID(named: ProviderIntentPayload.recordName(for: config.id))
        let record = self.record(type: .providerIntent, id: recordID)
        let existingSecretKeys = Set(record.encryptedValues.allKeys())
        let secretFields = try ProviderIntentPayload.secretFields(
            for: config,
            includeSecrets: includeSecrets,
            previouslyUploadedFields: existingSecretKeys)
        let unchanged = (record["payload"] as? String) == payload
            && self.encryptedStringFields(record) == secretFields
        guard !unchanged else { return }

        record["schemaVersion"] = CodexBarSyncSchema.currentVersion as CKRecordValue
        record["provider"] = config.id.rawValue as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["editCount"] = (self.editCount(record) + 1) as CKRecordValue
        record["modifiedAt"] = Date() as CKRecordValue
        for field in ProviderIntentSecretField.allCases {
            record.encryptedValues[field.rawValue] = nil
        }
        for (key, value) in secretFields {
            record.encryptedValues[key] = value as CKRecordValue
        }
        self.desiredRecords[recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private func queuePreferences(_ preferences: SyncedPreferences, engine: CKSyncEngine) throws {
        let payload = try CanonicalSyncJSON.string(PreferencesSyncPayload(preferences: preferences))
        let recordID = self.recordID(named: PreferencesSyncPayload.recordName)
        let record = self.record(type: .preferences, id: recordID)
        guard (record["payload"] as? String) != payload else { return }
        record["schemaVersion"] = CodexBarSyncSchema.currentVersion as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["editCount"] = (self.editCount(record) + 1) as CKRecordValue
        record["modifiedAt"] = Date() as CKRecordValue
        self.desiredRecords[recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private func queueDeviceRecord() async throws {
        guard let engine = self.engine else { return }
        let deviceID = await MainActor.run { self.settings.iCloudSyncDeviceID }
        let payload = DeviceSyncPayload(
            deviceID: deviceID,
            hostName: ProcessInfo.processInfo.hostName,
            model: Self.deviceModel(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            lastSeen: Date())
        let recordID = self.recordID(named: payload.recordName)
        let record = self.record(type: .device, id: recordID)
        record["schemaVersion"] = payload.schemaVersion as CKRecordValue
        record["deviceID"] = payload.deviceID as CKRecordValue
        record["hostName"] = payload.hostName as CKRecordValue
        record["model"] = payload.model as CKRecordValue
        record["appVersion"] = payload.appVersion as CKRecordValue
        record["lastSeen"] = payload.lastSeen as CKRecordValue
        self.desiredRecords[recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        await MainActor.run { self.state.fleetDevices[payload.recordName] = payload }
    }

    private func pushPendingSnapshots() async {
        guard let engine = self.engine, !self.pendingSnapshots.isEmpty else { return }
        guard await MainActor.run(body: { !self.state.status.needsAppUpdate }) else { return }
        do {
            for payload in self.pendingSnapshots {
                let hash = try CanonicalSyncJSON.hash(payload)
                guard self.lastSnapshotHashes[payload.recordName] != hash else { continue }
                let recordID = self.recordID(named: payload.recordName)
                let record = self.record(type: .accountSnapshot, id: recordID)
                record["schemaVersion"] = payload.schemaVersion as CKRecordValue
                record["provider"] = payload.provider.rawValue as CKRecordValue
                record["deviceID"] = payload.deviceID as CKRecordValue
                record["accountKey"] = payload.accountKey as CKRecordValue
                record["fetchedAt"] = payload.fetchedAt as CKRecordValue
                record.encryptedValues["displayLabel"] = payload.displayLabel as CKRecordValue
                record.encryptedValues["usagePayload"] = try CanonicalSyncJSON.string(payload.usage) as CKRecordValue
                self.desiredRecords[recordID] = record
                self.lastSnapshotHashes[payload.recordName] = hash
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
            self.pendingSnapshots = []
            self.lastSnapshotPushAt = Date()
        } catch {
            await self.record(error: error)
        }
    }

    // MARK: CKSyncEngineDelegate

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await self.processEvent(event, syncEngine: syncEngine)
    }

    private func processEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            self.persistenceEnvelope.stateSerialization = update.stateSerialization
            self.persistEnvelope()
        case let .accountChange(change):
            switch change.changeType {
            case .signOut, .switchAccounts:
                self.scheduleAccountReset()
            case .signIn:
                break
            @unknown default:
                self.scheduleAccountReset()
            }
        case let .fetchedRecordZoneChanges(changes):
            await self.applyFetchedRecords(changes.modifications.map(\.record))
            let deletedRecordNames = changes.deletions.map(\.recordID.recordName)
            for deletion in changes.deletions {
                self.persistenceEnvelope.encodedSystemFields.removeValue(forKey: deletion.recordID.recordName)
                self.persistenceEnvelope.recordFields.removeValue(forKey: deletion.recordID.recordName)
            }
            await MainActor.run {
                for recordName in deletedRecordNames {
                    self.state.fleetDevices.removeValue(forKey: recordName)
                    self.state.fleetSnapshots.removeValue(forKey: recordName)
                }
            }
            self.persistEnvelope()
            await MainActor.run { self.state.status.lastSuccessfulFetchAt = Date() }
        case let .sentRecordZoneChanges(changes):
            for record in changes.savedRecords {
                self.cacheSystemFields(record)
                self.desiredRecords.removeValue(forKey: record.recordID)
            }
            for failure in changes.failedRecordSaves {
                await self.handleSaveFailure(failure, syncEngine: syncEngine)
            }
            self.persistEnvelope()
            if !changes.savedRecords.isEmpty {
                await MainActor.run { self.state.status.lastSuccessfulPushAt = Date() }
            }
        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            }
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch?
    {
        await self.makeChangeBatch(context, syncEngine: syncEngine)
    }

    private func makeChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine) -> CKSyncEngine.RecordZoneChangeBatch?
    {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        var records: [CKRecord] = []
        var deletions: [CKRecord.ID] = []
        for change in changes {
            switch change {
            case let .saveRecord(recordID):
                if let record = self.desiredRecords[recordID] {
                    records.append(record)
                }
            case let .deleteRecord(recordID):
                deletions.append(recordID)
            @unknown default:
                continue
            }
        }
        guard !records.isEmpty || !deletions.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: deletions)
    }

    private func applyFetchedRecords(_ records: [CKRecord]) async {
        if records.contains(where: { self.schemaVersion($0) > CodexBarSyncSchema.currentVersion }) {
            await MainActor.run { self.state.status.needsAppUpdate = true }
            for record in records {
                self.cacheSystemFields(record)
            }
            return
        }
        guard await MainActor.run(body: { !self.state.status.needsAppUpdate }) else { return }

        for record in records {
            self.cacheSystemFields(record)
            guard self.shouldApplyServerRecord(record) else { continue }
            do {
                switch record.recordType {
                case SyncRecordType.providerIntent.rawValue:
                    try await self.applyProviderIntent(record)
                case SyncRecordType.preferences.rawValue:
                    try await self.applyPreferences(record)
                case SyncRecordType.device.rawValue:
                    try await self.applyDevice(record)
                case SyncRecordType.accountSnapshot.rawValue:
                    try await self.applyAccountSnapshot(record)
                default:
                    break
                }
            } catch {
                await self.record(error: error)
            }
        }
    }

    private func shouldApplyServerRecord(_ server: CKRecord) -> Bool {
        guard let engine = self.engine,
              engine.state.pendingRecordZoneChanges.contains(.saveRecord(server.recordID)),
              let local = self.desiredRecords[server.recordID],
              server.recordType == SyncRecordType.providerIntent.rawValue
              || server.recordType == SyncRecordType.preferences.rawValue
        else {
            return true
        }
        let localValue = SyncConflictValue(
            value: local,
            editCount: self.editCount(local),
            modifiedAt: self.modifiedAt(local))
        let serverValue = SyncConflictValue(
            value: server,
            editCount: self.editCount(server),
            modifiedAt: self.modifiedAt(server))
        let winner = SyncConflictResolver.winner(local: localValue, server: serverValue)
        guard winner.value === local else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
            self.desiredRecords.removeValue(forKey: server.recordID)
            return true
        }
        let rebased = self.copyUserFields(from: local, onto: server)
        self.desiredRecords[server.recordID] = rebased
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
        return false
    }

    private func applyProviderIntent(_ record: CKRecord) async throws {
        guard let payloadString = record["payload"] as? String else { return }
        let payload = try CanonicalSyncJSON.decode(ProviderIntentPayload.self, from: payloadString)
        let secrets = self.encryptedStringFields(record)
        try await MainActor.run {
            var config = self.settings.configSnapshot
            guard let local = config.providerConfig(for: payload.provider) else { return }
            let merged = try payload.applying(
                to: local,
                secretFields: secrets,
                canEnable: self.settings.canEnableProviderFromSync)
            config.setProviderConfig(merged)
            self.settings.applyExternalConfig(config, reason: "icloud", affectsBackgroundWork: true)
        }
    }

    private func applyPreferences(_ record: CKRecord) async throws {
        guard let payloadString = record["payload"] as? String else { return }
        let payload = try CanonicalSyncJSON.decode(PreferencesSyncPayload.self, from: payloadString)
        await MainActor.run {
            self.settings.applySyncedPreferences(payload.preferences)
        }
    }

    private func applyDevice(_ record: CKRecord) async throws {
        guard let deviceID = record["deviceID"] as? String,
              let hostName = record["hostName"] as? String,
              let model = record["model"] as? String,
              let appVersion = record["appVersion"] as? String,
              let lastSeen = record["lastSeen"] as? Date
        else { return }
        let payload = DeviceSyncPayload(
            deviceID: deviceID,
            hostName: hostName,
            model: model,
            appVersion: appVersion,
            lastSeen: lastSeen,
            schemaVersion: self.schemaVersion(record))
        await MainActor.run { self.state.fleetDevices[record.recordID.recordName] = payload }
    }

    private func applyAccountSnapshot(_ record: CKRecord) async throws {
        guard let providerRaw = record["provider"] as? String,
              let provider = UsageProvider(rawValue: providerRaw),
              let deviceID = record["deviceID"] as? String,
              let accountKey = record["accountKey"] as? String,
              let fetchedAt = record["fetchedAt"] as? Date,
              let displayLabel = record.encryptedValues["displayLabel"] as? String,
              let usagePayload = record.encryptedValues["usagePayload"] as? String
        else { return }
        let usage = try CanonicalSyncJSON.decode(UsageSnapshot.self, from: usagePayload)
        let payload = AccountSnapshotSyncPayload(
            provider: provider,
            deviceID: deviceID,
            accountKey: accountKey,
            fetchedAt: fetchedAt,
            displayLabel: displayLabel,
            usage: usage,
            schemaVersion: self.schemaVersion(record))
        await MainActor.run { self.state.fleetSnapshots[record.recordID.recordName] = payload }
    }

    private func handleSaveFailure(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine) async
    {
        switch failure.error.code {
        case .quotaExceeded:
            let retry = max(failure.error.retryAfterSeconds ?? 60, 5)
            self.scheduleRetry(recordID: failure.record.recordID, after: retry)
        case .serverRecordChanged:
            self.scheduleConflictResolution(recordID: failure.record.recordID)
        default:
            await self.record(error: failure.error)
        }
    }

    private func scheduleRetry(recordID: CKRecord.ID, after delay: TimeInterval) {
        Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                await Task.yield()
                guard let self, let engine = await self.engine, await self.enabled else { return }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                try await engine.sendChanges(.init(scope: .recordIDs([recordID])))
            } catch {
                await self?.record(error: error)
            }
        }
    }

    private func scheduleConflictResolution(recordID: CKRecord.ID) {
        Task { [weak self] in
            await Task.yield()
            guard let self, let engine = await self.engine else { return }
            do {
                let server = try await engine.database.record(for: recordID)
                await self.resolveConflict(with: server)
            } catch {
                await self.record(error: error)
            }
        }
    }

    private func resolveConflict(with server: CKRecord) async {
        guard let local = self.desiredRecords[server.recordID] else { return }
        self.cacheSystemFields(server)
        let localValue = SyncConflictValue(
            value: local,
            editCount: self.editCount(local),
            modifiedAt: self.modifiedAt(local))
        let serverValue = SyncConflictValue(
            value: server,
            editCount: self.editCount(server),
            modifiedAt: self.modifiedAt(server))
        if SyncConflictResolver.winner(local: localValue, server: serverValue).value === local {
            self.desiredRecords[server.recordID] = self.copyUserFields(from: local, onto: server)
            self.scheduleRetry(recordID: server.recordID, after: 0)
        } else {
            self.desiredRecords.removeValue(forKey: server.recordID)
            await self.applyFetchedRecords([server])
        }
    }

    private func scheduleAccountReset() {
        Task { [weak self] in
            await Task.yield()
            await self?.stopEngine(clearPersistence: true)
        }
    }

    private func scheduleFetchChanges() {
        Task { [weak self] in
            await Task.yield()
            await self?.fetchChanges()
        }
    }

    private func startPeriodicFetchTimer() {
        self.periodicFetchTask?.cancel()
        self.periodicFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15 * 60))
                } catch {
                    return
                }
                await self?.fetchChanges()
            }
        }
    }

    private func stopEngine(clearPersistence: Bool) async {
        self.configPushTask?.cancel()
        self.snapshotPushTask?.cancel()
        self.periodicFetchTask?.cancel()
        if let engine = self.engine {
            await engine.cancelOperations()
        }
        self.engine = nil
        self.desiredRecords = [:]
        self.lastQueuedConfigHash = nil
        if clearPersistence {
            self.persistenceEnvelope = .init(stateSerialization: nil, encodedSystemFields: [:])
            try? self.persistence.delete()
            await MainActor.run {
                self.state.fleetDevices = [:]
                self.state.fleetSnapshots = [:]
            }
        }
    }

    private func record(type: SyncRecordType, id: CKRecord.ID) -> CKRecord {
        if let data = self.persistenceEnvelope.encodedSystemFields[id.recordName],
           let record = CloudSyncPersistence.decodeRecord(from: data),
           record.recordType == type.rawValue
        {
            if let fields = self.persistenceEnvelope.recordFields[id.recordName] {
                for (key, value) in fields.strings {
                    record[key] = value as CKRecordValue
                }
                for (key, value) in fields.integers {
                    record[key] = value as CKRecordValue
                }
                for (key, value) in fields.dates {
                    record[key] = value as CKRecordValue
                }
                for (key, value) in fields.encryptedStrings {
                    record.encryptedValues[key] = value as CKRecordValue
                }
            }
            return record
        }
        return CKRecord(recordType: type.rawValue, recordID: id)
    }

    private func recordID(named recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: Self.zoneID)
    }

    private func cacheSystemFields(_ record: CKRecord) {
        self.persistenceEnvelope.encodedSystemFields[record.recordID.recordName] =
            CloudSyncPersistence.encodeSystemFields(of: record)
        var strings: [String: String] = [:]
        var integers: [String: Int64] = [:]
        var dates: [String: Date] = [:]
        for key in record.allKeys() {
            if let value = record[key] as? String {
                strings[key] = value
            } else if let value = record[key] as? NSNumber {
                integers[key] = value.int64Value
            } else if let value = record[key] as? Date {
                dates[key] = value
            }
        }
        self.persistenceEnvelope.recordFields[record.recordID.recordName] = .init(
            recordType: record.recordType,
            strings: strings,
            integers: integers,
            dates: dates,
            encryptedStrings: self.encryptedStringFields(record))
    }

    private func persistEnvelope() {
        do {
            try self.persistence.save(self.persistenceEnvelope)
        } catch {
            self.logger.error("Failed to persist CloudKit sync state: \(error)")
        }
    }

    private func encryptedStringFields(_ record: CKRecord) -> [String: String] {
        Dictionary(uniqueKeysWithValues: record.encryptedValues.allKeys().compactMap { key in
            (record.encryptedValues[key] as? String).map { (key, $0) }
        })
    }

    private func copyUserFields(from source: CKRecord, onto server: CKRecord) -> CKRecord {
        for key in server.allKeys() {
            server[key] = nil
        }
        for key in server.encryptedValues.allKeys() {
            server.encryptedValues[key] = nil
        }
        for key in source.allKeys() {
            server[key] = source[key]
        }
        for key in source.encryptedValues.allKeys() {
            server.encryptedValues[key] = source.encryptedValues[key]
        }
        return server
    }

    private func editCount(_ record: CKRecord) -> Int64 {
        (record["editCount"] as? NSNumber)?.int64Value ?? 0
    }

    private func modifiedAt(_ record: CKRecord) -> Date {
        record["modifiedAt"] as? Date ?? .distantPast
    }

    private func schemaVersion(_ record: CKRecord) -> Int {
        (record["schemaVersion"] as? NSNumber)?.intValue ?? 0
    }

    private func updateAvailability(_ availability: SyncAvailability) async {
        await MainActor.run { self.state.availability = availability }
    }

    private func record(error: Error) async {
        self.logger.error("iCloud sync failed: \(error)")
        await MainActor.run { self.state.status.lastError = error.localizedDescription }
    }

    private static func deviceModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(bytes: bytes, encoding: .utf8) ?? "unknown"
    }
}
