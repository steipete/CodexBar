import CodexBarCore
import Foundation

protocol CodexAccountUsageSnapshotStoring: Sendable {
    func load(for accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot]
    func store(_ snapshots: [CodexAccountUsageSnapshot])
}

struct FileCodexAccountUsageSnapshotStore: CodexAccountUsageSnapshotStoring, @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        let records: [Record]
    }

    private struct Record: Codable {
        let id: String
        let snapshot: UsageSnapshot?
        let error: String?
        let sourceLabel: String?
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load(for accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot] {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion
        else {
            return []
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return payload.records.compactMap { record in
            guard let account = accountsByID[record.id] else { return nil }
            return CodexAccountUsageSnapshot(
                account: account,
                snapshot: record.snapshot,
                error: record.error,
                sourceLabel: record.sourceLabel)
        }
    }

    func store(_ snapshots: [CodexAccountUsageSnapshot]) {
        let payload = Payload(
            version: Self.currentVersion,
            records: snapshots.map { snapshot in
                Record(
                    id: snapshot.id,
                    snapshot: snapshot.snapshot,
                    error: snapshot.error,
                    sourceLabel: snapshot.sourceLabel)
            })
        let directory = self.fileURL.deletingLastPathComponent()
        do {
            if !self.fileManager.fileExists(atPath: directory.path) {
                try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: self.fileURL, options: [.atomic])
            #if os(macOS)
            try self.fileManager.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: self.fileURL.path)
            #endif
        } catch {
            // Snapshot hydration is best-effort; never make menu refresh fail because disk cache failed.
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("codex-account-snapshots.json", isDirectory: false)
    }
}
