import CloudKit
import CodexBarCore
import Foundation

struct CloudSyncPersistence: Sendable {
    struct RecordMetadata: Codable, Sendable {
        var recordType: String
        var schemaVersion: Int?
        var editCount: Int64?
        var modifiedAt: Date?
    }

    struct Envelope: Codable, Sendable {
        var stateSerialization: CKSyncEngine.State.Serialization?
        var encodedSystemFields: [String: Data]
        var recordMetadata: [String: RecordMetadata]
        var suppressedEnableIntents: Set<String>
        var dirtyProviders: Set<String>
        var preferencesDirty: Bool
        var fleetDevices: [String: DeviceSyncPayload]
        var fleetSnapshots: [String: AccountSnapshotSyncPayload]

        init(
            stateSerialization: CKSyncEngine.State.Serialization?,
            encodedSystemFields: [String: Data],
            recordMetadata: [String: RecordMetadata] = [:],
            suppressedEnableIntents: Set<String> = [],
            dirtyProviders: Set<String> = [],
            preferencesDirty: Bool = false,
            fleetDevices: [String: DeviceSyncPayload] = [:],
            fleetSnapshots: [String: AccountSnapshotSyncPayload] = [:])
        {
            self.stateSerialization = stateSerialization
            self.encodedSystemFields = encodedSystemFields
            self.recordMetadata = recordMetadata
            self.suppressedEnableIntents = suppressedEnableIntents
            self.dirtyProviders = dirtyProviders
            self.preferencesDirty = preferencesDirty
            self.fleetDevices = fleetDevices
            self.fleetSnapshots = fleetSnapshots
        }

        private enum CodingKeys: String, CodingKey {
            case stateSerialization
            case encodedSystemFields
            case recordMetadata
            case suppressedEnableIntents
            case dirtyProviders
            case preferencesDirty
            case fleetDevices
            case fleetSnapshots
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.stateSerialization = try container.decodeIfPresent(
                CKSyncEngine.State.Serialization.self,
                forKey: .stateSerialization)
            self.encodedSystemFields = try container.decodeIfPresent(
                [String: Data].self,
                forKey: .encodedSystemFields) ?? [:]
            self.recordMetadata = try container.decodeIfPresent(
                [String: RecordMetadata].self,
                forKey: .recordMetadata) ?? [:]
            self.suppressedEnableIntents = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .suppressedEnableIntents) ?? []
            self.dirtyProviders = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .dirtyProviders) ?? []
            self.preferencesDirty = try container.decodeIfPresent(
                Bool.self,
                forKey: .preferencesDirty) ?? false
            self.fleetDevices = try container.decodeIfPresent(
                [String: DeviceSyncPayload].self,
                forKey: .fleetDevices) ?? [:]
            self.fleetSnapshots = try container.decodeIfPresent(
                [String: AccountSnapshotSyncPayload].self,
                forKey: .fleetSnapshots) ?? [:]
        }
    }

    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() -> Envelope {
        guard let data = try? Data(contentsOf: self.fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            return Envelope(stateSerialization: nil, encodedSystemFields: [:])
        }
        // Rewriting also strips the legacy recordFields payload, which could contain encrypted values.
        try? self.save(envelope)
        return envelope
    }

    func save(_ envelope: Envelope) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: self.fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        try FileManager.default.removeItem(at: self.fileURL)
    }

    static func encodeSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func decodeRecord(from data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    static func cacheSystemFields(of record: CKRecord, in envelope: inout Envelope) {
        envelope.encodedSystemFields[record.recordID.recordName] = self.encodeSystemFields(of: record)
        envelope.recordMetadata[record.recordID.recordName] = RecordMetadata(
            recordType: record.recordType,
            schemaVersion: (record["schemaVersion"] as? NSNumber)?.intValue,
            editCount: (record["editCount"] as? NSNumber)?.int64Value,
            modifiedAt: record["modifiedAt"] as? Date)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.steipete.codexbar", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("engine-state.json")
    }
}
