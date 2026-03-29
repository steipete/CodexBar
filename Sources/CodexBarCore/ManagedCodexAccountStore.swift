import Foundation

public enum FileManagedCodexAccountStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

public protocol ManagedCodexAccountStoring: Sendable {
    func loadAccounts() throws -> ManagedCodexAccountSet
    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws
    func ensureFileExists() throws -> URL
}

public struct FileManagedCodexAccountStore: ManagedCodexAccountStoring, @unchecked Sendable {
    public static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadAccounts() throws -> ManagedCodexAccountSet {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else {
            return Self.emptyAccountSet()
        }

        let data = try Data(contentsOf: self.fileURL)
        let decoder = JSONDecoder()
        let accounts = try decoder.decode(ManagedCodexAccountSet.self, from: data)
        guard accounts.version == Self.currentVersion else {
            throw FileManagedCodexAccountStoreError.unsupportedVersion(accounts.version)
        }
        return accounts
    }

    public func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        let normalizedAccounts = ManagedCodexAccountSet(
            version: Self.currentVersion,
            accounts: accounts.accounts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalizedAccounts)
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: self.fileURL, options: [.atomic])
        try self.applySecurePermissionsIfNeeded()
    }

    public func ensureFileExists() throws -> URL {
        if self.fileManager.fileExists(atPath: self.fileURL.path) { return self.fileURL }
        try self.storeAccounts(Self.emptyAccountSet())
        return self.fileURL
    }

    private func applySecurePermissionsIfNeeded() throws {
        #if os(macOS)
        try self.fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: self.fileURL.path)
        #endif
    }

    private static func emptyAccountSet() -> ManagedCodexAccountSet {
        ManagedCodexAccountSet(version: self.currentVersion, accounts: [])
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-codex-accounts.json")
    }
}
