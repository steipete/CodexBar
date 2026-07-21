import Foundation
import SQLite3

/// Reads Kiro CLI OAuth material from the local SQLite auth store.
///
/// ponytail: injectable `databaseURL` keeps filesystem access out of fetch strategies and
/// mirrors `OpenCodeGoLocalUsageReader`.
struct KiroCLICredentialStore: Sendable {
    static let enterpriseStorageKeySuffixes = ["oidc:token", "odic:token"]
    static let socialStorageKey = "kirocli:social:token"

    private static let storageKeys = [
        "kirocli:odic:token",
        "kirocli:oidc:token",
        socialStorageKey,
    ]

    let databaseURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.databaseURL = homeDirectory
            .appendingPathComponent("Library/Application Support/kiro-cli", isDirectory: true)
            .appendingPathComponent("data.sqlite3", isDirectory: false)
    }

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func loadCredentials(allowSocial: Bool) -> KiroCLICredentials? {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        for key in Self.storageKeys {
            let isSocial = key == Self.socialStorageKey
            if isSocial, !allowSocial { continue }
            if let credentials = Self.queryCredentials(db: db, storageKey: key) {
                if !allowSocial, !credentials.isEnterpriseAffected { continue }
                return credentials
            }
        }
        return nil
    }

    private static func queryCredentials(db: OpaquePointer?, storageKey: String) -> KiroCLICredentials? {
        guard let db else { return nil }
        let query = "SELECT value FROM auth_kv WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, storageKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blob = sqlite3_column_text(stmt, 0)
        else {
            return nil
        }

        let jsonString = String(cString: blob)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        guard let accessToken = Self.string(json, keys: "access_token", "accessToken"),
              !accessToken.isEmpty
        else {
            return nil
        }

        return KiroCLICredentials(
            storageKey: storageKey,
            accessToken: accessToken,
            refreshToken: Self.string(json, keys: "refresh_token", "refreshToken"),
            expiresAt: Self.parseExpires(json),
            region: Self.string(json, keys: "region"),
            authRegion: Self.string(json, keys: "auth_region", "authRegion"),
            startURL: Self.string(json, keys: "start_url", "startUrl"),
            tokenEndpoint: Self.string(json, keys: "token_endpoint", "tokenEndpoint"),
            scopes: Self.string(json, keys: "scopes", "scope"),
            clientID: Self.string(json, keys: "client_id", "clientId"),
            clientSecret: Self.string(json, keys: "client_secret", "clientSecret"),
            authMethod: Self.string(json, keys: "auth_method", "authMethod"),
            provider: Self.string(json, keys: "provider"),
            machineID: Self.string(json, keys: "machine_id", "machineId"))
    }

    private static func string(_ json: [String: Any], keys: String...) -> String? {
        for key in keys {
            guard let value = json[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func parseExpires(_ json: [String: Any]) -> Date? {
        if let expiresAt = self.string(json, keys: "expires_at", "expiresAt") {
            return parseISO8601Date(expiresAt)
        }
        if let expiresIn = json["expires_in"] as? Int ?? json["expiresIn"] as? Int {
            return Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        if let expiresIn = json["expires_in"] as? Double ?? json["expiresIn"] as? Double {
            return Date().addingTimeInterval(expiresIn)
        }
        return nil
    }
}

struct KiroCLICredentials: Sendable, Equatable {
    let storageKey: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let region: String?
    let authRegion: String?
    let startURL: String?
    let tokenEndpoint: String?
    let scopes: String?
    let clientID: String?
    let clientSecret: String?
    let authMethod: String?
    let provider: String?
    let machineID: String?

    var canonicalAuthMethod: String {
        Self.canonicalizeAuthMethod(self.authMethod, tokenEndpoint: self.tokenEndpoint)
    }

    var isExternalIDP: Bool {
        self.canonicalAuthMethod == "external_idp"
    }

    var isEnterpriseAffected: Bool {
        if KiroCLICredentialStore.enterpriseStorageKeySuffixes.contains(where: { self.storageKey.hasSuffix($0) }) {
            return true
        }
        let method = self.canonicalAuthMethod
        if method == "idc" || method == "external_idp" { return true }
        if let startURL = self.startURL, !startURL.isEmpty { return true }
        if let tokenEndpoint = self.tokenEndpoint, !tokenEndpoint.isEmpty { return true }
        return false
    }

    var tokenTypeHeader: String? {
        if self.canonicalAuthMethod == "api_key" { return "API_KEY" }
        if self.isExternalIDP { return "EXTERNAL_IDP" }
        return nil
    }

    var effectiveAuthRegion: String {
        self.authRegion ?? self.region ?? "us-east-1"
    }

    func needsRefresh(now: Date = Date(), buffer: TimeInterval = 5 * 60) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) <= buffer
    }

    static func canonicalizeAuthMethod(_ raw: String?, tokenEndpoint: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized: String = switch trimmed.lowercased() {
        case "builder-id", "iam": "idc"
        case "api_key", "apikey": "api_key"
        case "external_idp", "azuread", "azure", "entra", "entra-id", "microsoft", "m365", "office365", "external":
            "external_idp"
        case "": ""
        default: trimmed.lowercased()
        }

        if normalized == "external_idp" { return "external_idp" }
        if let tokenEndpoint, !tokenEndpoint.isEmpty { return "external_idp" }
        return normalized.isEmpty ? "social" : normalized
    }

    static func validateExternalIDPEndpoint(_ rawURL: String) throws {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else {
            throw KiroAPIError.invalidExternalIDPEndpoint
        }

        guard url.scheme?.lowercased() == "https" else {
            throw KiroAPIError.invalidExternalIDPEndpoint
        }

        if host.contains(":") || host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            throw KiroAPIError.invalidExternalIDPEndpoint
        }

        let allowedSuffixes = [
            ".microsoftonline.com",
            ".microsoftonline.us",
            ".microsoftonline.cn",
        ]
        guard allowedSuffixes.contains(where: { host.hasSuffix($0) }) else {
            throw KiroAPIError.invalidExternalIDPEndpoint
        }
    }
}

extension KiroCLICredentialStore {
    fileprivate static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
