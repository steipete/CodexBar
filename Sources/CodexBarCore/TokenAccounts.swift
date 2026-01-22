import Foundation

public struct ProviderTokenAccount: Codable, Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let token: String
    public let addedAt: TimeInterval
    public let lastUsed: TimeInterval?

    public init(id: UUID, label: String, token: String, addedAt: TimeInterval, lastUsed: TimeInterval?) {
        self.id = id
        self.label = label
        self.token = token
        self.addedAt = addedAt
        self.lastUsed = lastUsed
    }

    public var displayName: String {
        self.label
    }
}

public struct ProviderTokenAccountData: Codable, Sendable {
    public let version: Int
    public let accounts: [ProviderTokenAccount]
    public let activeIndex: Int

    public init(version: Int, accounts: [ProviderTokenAccount], activeIndex: Int) {
        self.version = version
        self.accounts = accounts
        self.activeIndex = activeIndex
    }

    public func clampedActiveIndex() -> Int {
        guard !self.accounts.isEmpty else { return 0 }
        return min(max(self.activeIndex, 0), self.accounts.count - 1)
    }
}

private struct ProviderTokenAccountsFile: Codable {
    let version: Int
    let providers: [String: ProviderTokenAccountData]
}

public protocol ProviderTokenAccountStoring: Sendable {
    func loadAccounts() throws -> [UsageProvider: ProviderTokenAccountData]
    func storeAccounts(_ accounts: [UsageProvider: ProviderTokenAccountData]) throws
    func ensureFileExists() throws -> URL
}

public struct FileTokenAccountStore: ProviderTokenAccountStoring, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadAccounts() throws -> [UsageProvider: ProviderTokenAccountData] {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return [:] }
        let data = try Data(contentsOf: self.fileURL)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ProviderTokenAccountsFile.self, from: data)
        var result: [UsageProvider: ProviderTokenAccountData] = [:]
        for (key, value) in decoded.providers {
            guard let provider = UsageProvider(rawValue: key) else { continue }
            result[provider] = value
        }
        return result
    }

    public func storeAccounts(_ accounts: [UsageProvider: ProviderTokenAccountData]) throws {
        let payload = ProviderTokenAccountsFile(
            version: 1,
            providers: Dictionary(uniqueKeysWithValues: accounts.map { ($0.key.rawValue, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: self.fileURL, options: [.atomic])
        try self.applySecurePermissionsIfNeeded()
    }

    public func ensureFileExists() throws -> URL {
        if self.fileManager.fileExists(atPath: self.fileURL.path) { return self.fileURL }
        try self.storeAccounts([:])
        return self.fileURL
    }

    private func applySecurePermissionsIfNeeded() throws {
        #if os(macOS)
        try self.fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: self.fileURL.path)
        #endif
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("token-accounts.json")
    }
}
