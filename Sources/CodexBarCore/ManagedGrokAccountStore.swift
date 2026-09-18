import Foundation

public enum FileManagedGrokAccountStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

public protocol ManagedGrokAccountStoring: Sendable {
    func loadAccounts() throws -> ManagedGrokAccountSet
    func storeAccounts(_ accounts: ManagedGrokAccountSet) throws
}

public struct FileManagedGrokAccountStore: ManagedGrokAccountStoring, @unchecked Sendable {
    public static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadAccounts() throws -> ManagedGrokAccountSet {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else {
            return Self.emptyAccountSet()
        }

        let data = try Data(contentsOf: self.fileURL)
        let decoder = JSONDecoder()
        let accounts = try decoder.decode(ManagedGrokAccountSet.self, from: data)
        guard (1...Self.currentVersion).contains(accounts.version) else {
            throw FileManagedGrokAccountStoreError.unsupportedVersion(accounts.version)
        }
        return ManagedGrokAccountSet(version: Self.currentVersion, accounts: accounts.accounts)
    }

    public func storeAccounts(_ accounts: ManagedGrokAccountSet) throws {
        let normalizedAccounts = ManagedGrokAccountSet(
            version: Self.currentVersion,
            accounts: accounts.accounts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalizedAccounts)
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try CredentialFileWriter.writePrivate(data, to: self.fileURL)
    }

    private static func emptyAccountSet() -> ManagedGrokAccountSet {
        ManagedGrokAccountSet(version: self.currentVersion, accounts: [])
    }

    public static func defaultURL() -> URL {
        if CodexCredentialFileAccess.isTestContext {
            return self.processLocalTestURL
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-grok-accounts.json")
    }

    private static let processLocalTestURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codexbar-managed-grok-accounts-\(ProcessInfo.processInfo.processIdentifier).json")
}
