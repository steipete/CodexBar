import CloudKit
import Foundation

struct CloudSyncPersistence: Sendable {
    struct RecordFields: Codable, Sendable {
        var recordType: String
        var strings: [String: String]
        var integers: [String: Int64]
        var dates: [String: Date]
        var encryptedStrings: [String: String]
    }

    struct Envelope: Codable, Sendable {
        var stateSerialization: CKSyncEngine.State.Serialization?
        var encodedSystemFields: [String: Data]
        var recordFields: [String: RecordFields]

        init(
            stateSerialization: CKSyncEngine.State.Serialization?,
            encodedSystemFields: [String: Data],
            recordFields: [String: RecordFields] = [:])
        {
            self.stateSerialization = stateSerialization
            self.encodedSystemFields = encodedSystemFields
            self.recordFields = recordFields
        }

        private enum CodingKeys: String, CodingKey {
            case stateSerialization
            case encodedSystemFields
            case recordFields
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.stateSerialization = try container.decodeIfPresent(
                CKSyncEngine.State.Serialization.self,
                forKey: .stateSerialization)
            self.encodedSystemFields = try container.decodeIfPresent(
                [String: Data].self,
                forKey: .encodedSystemFields) ?? [:]
            self.recordFields = try container.decodeIfPresent(
                [String: RecordFields].self,
                forKey: .recordFields) ?? [:]
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
        return envelope
    }

    func save(_ envelope: Envelope) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: self.fileURL, options: [.atomic])
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

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.steipete.codexbar", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("engine-state.json")
    }
}
