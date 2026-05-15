import Foundation

public struct GrokCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let scope: String
    public let authMode: String?
    public let userId: String?
    public let email: String?
    public let firstName: String?
    public let lastName: String?
    public let teamId: String?
    public let oidcIssuer: String?
    public let oidcClientId: String?
    public let expiresAt: Date?
    public let createTime: Date?

    public init(
        accessToken: String,
        refreshToken: String?,
        scope: String,
        authMode: String?,
        userId: String?,
        email: String?,
        firstName: String?,
        lastName: String?,
        teamId: String?,
        oidcIssuer: String?,
        oidcClientId: String?,
        expiresAt: Date?,
        createTime: Date?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.scope = scope
        self.authMode = authMode
        self.userId = userId
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.teamId = teamId
        self.oidcIssuer = oidcIssuer
        self.oidcClientId = oidcClientId
        self.expiresAt = expiresAt
        self.createTime = createTime
    }

    public var displayName: String? {
        let parts = [self.firstName, self.lastName].compactMap { $0?.nilIfEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    public var loginMethod: String? {
        switch self.authMode?.lowercased() {
        case "oidc": "SuperGrok"
        case "session": "session"
        case nil: nil
        default: self.authMode
        }
    }
}

public enum GrokCredentialsError: LocalizedError, Sendable {
    case notFound
    case decodeFailed(String)
    case missingTokens

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Grok auth.json not found. Run `grok login` to authenticate."
        case let .decodeFailed(message):
            "Failed to decode Grok credentials: \(message)"
        case .missingTokens:
            "Grok auth.json exists but contains no access tokens."
        }
    }
}

public enum GrokCredentialsStore {
    /// Top-level OIDC scope used by `grok login` for SuperGrok subscribers.
    public static let oidcScopePrefix = "https://auth.x.ai::"
    /// Legacy/session scope used by older `grok login` flows.
    public static let legacySessionScope = "https://accounts.x.ai/sign-in"

    public static func grokHomeURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        if let custom = env["GROK_HOME"]?.nilIfEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".grok", isDirectory: true)
    }

    public static func authFileURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        self.grokHomeURL(env: env, fileManager: fileManager).appendingPathComponent("auth.json")
    }

    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) throws -> GrokCredentials {
        let url = self.authFileURL(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GrokCredentialsError.notFound
        }
        let data = try Data(contentsOf: url)
        return try self.parse(data: data)
    }

    public static func parse(data: Data) throws -> GrokCredentials {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GrokCredentialsError.decodeFailed(error.localizedDescription)
        }
        guard let root = raw as? [String: Any] else {
            throw GrokCredentialsError.decodeFailed("Invalid JSON (expected object at root)")
        }

        // `auth.json` is a map keyed by scope URL. Prefer the OIDC scope (SuperGrok),
        // fall back to the legacy session scope.
        let preferredEntry = Self.selectPreferredEntry(in: root)
        guard let (scope, entry) = preferredEntry else {
            throw GrokCredentialsError.missingTokens
        }
        guard let key = entry["key"] as? String, !key.isEmpty else {
            throw GrokCredentialsError.missingTokens
        }

        return GrokCredentials(
            accessToken: key,
            refreshToken: (entry["refresh_token"] as? String)?.nilIfEmpty,
            scope: scope,
            authMode: (entry["auth_mode"] as? String)?.nilIfEmpty,
            userId: (entry["user_id"] as? String)?.nilIfEmpty,
            email: (entry["email"] as? String)?.nilIfEmpty,
            firstName: (entry["first_name"] as? String)?.nilIfEmpty,
            lastName: (entry["last_name"] as? String)?.nilIfEmpty,
            teamId: (entry["team_id"] as? String)?.nilIfEmpty,
            oidcIssuer: (entry["oidc_issuer"] as? String)?.nilIfEmpty,
            oidcClientId: (entry["oidc_client_id"] as? String)?.nilIfEmpty,
            expiresAt: Self.parseDate(entry["expires_at"]),
            createTime: Self.parseDate(entry["create_time"]))
    }

    private static func selectPreferredEntry(in root: [String: Any]) -> (scope: String, entry: [String: Any])? {
        var oidcCandidate: (String, [String: Any])?
        var legacyCandidate: (String, [String: Any])?
        for (scope, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            if scope.hasPrefix(self.oidcScopePrefix) {
                oidcCandidate = (scope, entry)
            } else if scope == self.legacySessionScope || scope.contains("/sign-in") {
                legacyCandidate = (scope, entry)
            }
        }
        return oidcCandidate ?? legacyCandidate
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
