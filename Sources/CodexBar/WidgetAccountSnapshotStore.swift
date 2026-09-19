import CodexBarCore
import Foundation

struct WidgetVerifiedTokenSnapshot: Codable, Sendable {
    let credentialScope: String
    let widgetID: String
    let usage: WidgetSnapshot.ProviderEntry
}

typealias WidgetVerifiedTokenSnapshots = [UsageProvider: [UUID: WidgetVerifiedTokenSnapshot]]

@MainActor
protocol WidgetAccountSnapshotStoring {
    func load() -> WidgetVerifiedTokenSnapshots
    func save(_ snapshots: WidgetVerifiedTokenSnapshots)
}

/// Private app storage, separate from the widget app group and Cloud Sync. Labels and credentials are not stored.
@MainActor
final class FileWidgetAccountSnapshotStore: WidgetAccountSnapshotStoring {
    private struct Payload: Codable {
        let version: Int
        let snapshots: WidgetVerifiedTokenSnapshots
    }

    private let url: URL
    private var lastSavedData: Data?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar/widget-account-snapshots.json")
    }

    func load() -> WidgetVerifiedTokenSnapshots {
        guard let size = try? self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: self.url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1
        else { return [:] }
        self.lastSavedData = data
        return payload.snapshots.reduce(into: [:]) { result, entry in
            let (provider, records) = entry
            let valid = records.compactMapValues { record -> WidgetVerifiedTokenSnapshot? in
                guard record.usage.provider == provider.instanceID,
                      record.credentialScope.count == 64, record.credentialScope.allSatisfy(\.isHexDigit),
                      record.widgetID.hasPrefix("\(provider.rawValue)/token:")
                else { return nil }
                let usage = record.usage
                return WidgetVerifiedTokenSnapshot(
                    credentialScope: record.credentialScope,
                    widgetID: record.widgetID,
                    usage: WidgetSnapshot.ProviderEntry(
                        provider: provider,
                        updatedAt: usage.updatedAt,
                        primary: usage.primary,
                        secondary: usage.secondary,
                        tertiary: usage.tertiary,
                        usageRows: usage.usageRows,
                        creditsRemaining: nil,
                        codeReviewRemainingPercent: nil,
                        tokenUsage: nil,
                        dailyUsage: []))
            }
            if !valid.isEmpty { result[provider] = valid }
        }
    }

    func save(_ snapshots: WidgetVerifiedTokenSnapshots) {
        let snapshots = snapshots.filter { !$0.value.isEmpty }
        guard !snapshots.isEmpty else {
            try? FileManager.default.removeItem(at: self.url)
            self.lastSavedData = nil
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Payload(version: 1, snapshots: snapshots)),
              data.count <= 4 * 1024 * 1024, data != self.lastSavedData
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: self.url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
            self.lastSavedData = data
        } catch {
            // Widget publication still succeeds if the private restart cache is unavailable.
        }
    }
}
