import Crypto
import Foundation

public struct BorrowedCodexAccount: Sendable, Identifiable {
    public let id: String
    public let email: String
    public let accountId: String
    public let credentials: CodexOAuthCredentials
    public let expired: Date?
    public let isExpired: Bool
    public let sourcePath: String

    public init(
        id: String,
        email: String,
        accountId: String,
        credentials: CodexOAuthCredentials,
        expired: Date?,
        isExpired: Bool,
        sourcePath: String)
    {
        self.id = id
        self.email = email
        self.accountId = accountId
        self.credentials = credentials
        self.expired = expired
        self.isExpired = isExpired
        self.sourcePath = sourcePath
    }
}

public struct CLIProxyCodexAccountPreview: Sendable, Identifiable {
    public let id: String
    public let email: String
    public let accountId: String
    public let expired: Date?
    public let isExpired: Bool
    public let isDisabled: Bool
    public let sourcePath: String
}

public enum CLIProxyCodexAdapter {
    public static let format = "cliproxyapi-codex"

    public static func loadAccounts(
        from path: String,
        now: Date,
        fileManager: FileManager = .default) -> [BorrowedCodexAccount]
    {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let files = self.credentialFiles(from: url, fileManager: fileManager)
        return files.compactMap { self.loadAccount(from: $0, now: now) }
    }

    public static func previewAccounts(
        from path: String,
        now: Date,
        fileManager: FileManager = .default) -> [CLIProxyCodexAccountPreview]
    {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let files = self.credentialFiles(from: url, fileManager: fileManager)
        return files.compactMap { self.previewAccount(from: $0, now: now) }
    }

    private static func credentialFiles(from url: URL, fileManager: FileManager) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return self.isCredentialFile(url) ? [url] : [] }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        return contents
            .filter(self.isCredentialFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isCredentialFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("codex-") && url.pathExtension == "json"
    }

    private static func loadAccount(from url: URL, now: Date) -> BorrowedCodexAccount? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CLIProxyCodexFile.self, from: data),
              file.type == "codex",
              file.disabled != true
        else {
            return nil
        }

        let lastRefresh = self.parseISO8601(file.lastRefresh)
        let expired = self.parseISO8601(file.expired)
        let sourcePath = self.standardizedPath(for: url)
        let credentials = CodexOAuthCredentials(
            accessToken: file.accessToken,
            refreshToken: file.refreshToken,
            idToken: file.idToken,
            accountId: file.accountId,
            lastRefresh: lastRefresh)

        return BorrowedCodexAccount(
            id: self.accountID(accountId: file.accountId, sourcePath: sourcePath),
            email: file.email,
            accountId: file.accountId,
            credentials: credentials,
            expired: expired,
            isExpired: expired.map { $0 <= now } ?? false,
            sourcePath: sourcePath)
    }

    private static func previewAccount(from url: URL, now: Date) -> CLIProxyCodexAccountPreview? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CLIProxyCodexFile.self, from: data),
              file.type == "codex"
        else {
            return nil
        }

        let expired = self.parseISO8601(file.expired)
        let sourcePath = self.standardizedPath(for: url)
        return CLIProxyCodexAccountPreview(
            id: self.accountID(accountId: file.accountId, sourcePath: sourcePath),
            email: file.email,
            accountId: file.accountId,
            expired: expired,
            isExpired: expired.map { $0 <= now } ?? false,
            isDisabled: file.disabled == true,
            sourcePath: sourcePath)
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func accountID(accountId: String, sourcePath: String) -> String {
        "borrowed:\(accountId):\(self.sourcePathHash(sourcePath))"
    }

    private static func sourcePathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func standardizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

private struct CLIProxyCodexFile: Decodable {
    let type: String
    let email: String
    let accountId: String
    let accessToken: String
    let idToken: String
    let refreshToken: String
    let lastRefresh: String?
    let expired: String?
    let disabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case email
        case accountId = "account_id"
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case lastRefresh = "last_refresh"
        case expired
        case disabled
    }
}
