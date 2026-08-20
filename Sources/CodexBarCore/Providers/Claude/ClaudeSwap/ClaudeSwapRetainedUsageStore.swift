#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Slot-keyed usage windows from the last successful Claude Swap projection.
/// Display labels and emails stay out of the cache so one-shot CLI/dashboard
/// calls can retain at-limit bars without persisting identity. A SHA-256
/// fingerprint binds those windows to the account that produced them.
public enum ClaudeSwapRetainedUsageStore {
    private static let fingerprintPrefix = "fp:"

    public static func load() -> [ProviderAccountUsageSnapshot] {
        guard let url = self.resolvedFileURL(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return records.map(\.account)
    }

    /// After a relaunch the in-memory array is empty even when this cache still
    /// holds complete windows, so fall back to disk only when nothing is in memory.
    public static func previousAccounts(
        inMemory: [ProviderAccountUsageSnapshot]) -> [ProviderAccountUsageSnapshot]
    {
        inMemory.isEmpty ? self.load() : inMemory
    }

    public static func save(_ accounts: [ProviderAccountUsageSnapshot]) {
        guard let url = self.resolvedFileURL() else { return }
        let records = accounts.compactMap(Record.init(account:))
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// In-memory equivalent of save/load, used to prove cache-shaped previous snapshots
    /// still reject a different account in the same slot.
    static func snapshotsForRetention(
        _ accounts: [ProviderAccountUsageSnapshot]) -> [ProviderAccountUsageSnapshot]
    {
        accounts.compactMap(Record.init(account:)).map(\.account)
    }

    static func fingerprint(email: String, slot: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@") else { return nil }
        let material = "\(slot)\u{0}\(trimmed)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(from account: ProviderAccountUsageSnapshot) -> String? {
        if let stored = account.snapshot?.identity?.accountID,
           stored.hasPrefix(self.fingerprintPrefix)
        {
            return String(stored.dropFirst(self.fingerprintPrefix.count))
        }
        let email = account.snapshot?.identity?.accountEmail ?? account.displayLabel
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return self.fingerprint(email: email, slot: account.id.opaqueID)
    }

    static func fingerprintAccountID(_ fingerprint: String) -> String {
        self.fingerprintPrefix + fingerprint
    }

    private static func resolvedFileURL() -> URL? {
        if self.isRunningTests { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("claude-swap-retained-usage.json")
    }

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        if ProcessInfo.processInfo.processName.lowercased().contains("xctest") {
            return true
        }
        return CommandLine.arguments.contains { $0.lowercased().contains(".xctest") }
    }

    private struct Record: Codable {
        var opaqueID: String
        var accountFingerprint: String
        var primary: RateWindow?
        var secondary: RateWindow?
        var extraRateWindows: [NamedRateWindow]?
        var updatedAt: Date

        init?(account: ProviderAccountUsageSnapshot) {
            guard account.id.source == ClaudeSwapAccountProjection.sourceName,
                  let snapshot = account.snapshot
            else { return nil }
            self.opaqueID = account.id.opaqueID
            guard let fingerprint = ClaudeSwapRetainedUsageStore.fingerprint(
                email: snapshot.identity?.accountEmail ?? account.displayLabel,
                slot: account.id.opaqueID)
            else {
                return nil
            }
            self.accountFingerprint = fingerprint
            self.primary = snapshot.primary
            self.secondary = snapshot.secondary
            self.extraRateWindows = snapshot.extraRateWindows
            self.updatedAt = snapshot.updatedAt
        }

        var account: ProviderAccountUsageSnapshot {
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(
                    source: ClaudeSwapAccountProjection.sourceName,
                    opaqueID: self.opaqueID),
                provider: .claude,
                displayLabel: "",
                isActive: false,
                snapshot: UsageSnapshot(
                    primary: self.primary,
                    secondary: self.secondary,
                    extraRateWindows: self.extraRateWindows,
                    updatedAt: self.updatedAt,
                    identity: ProviderIdentitySnapshot(
                        providerID: .claude,
                        accountEmail: nil,
                        accountOrganization: nil,
                        loginMethod: ClaudeSwapAccountProjection.sourceLabel,
                        accountID: ClaudeSwapRetainedUsageStore.fingerprintAccountID(self.accountFingerprint))),
                error: nil,
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
        }
    }
}
