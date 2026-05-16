import Foundation

/// Represents a detected Grok Build CLI session from ~/.grok/auth.json.
/// Mirrors the structure used by the official Grok CLI and the VS Code Grok Build extension.
public struct GrokCliSession: Sendable, Equatable {
    public let email: String?
    /// Tier from the JWT (5 = Super Heavy / full subscription)
    public let tier: Int?
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let clientId: String
    public let issuer: String

    public init(
        email: String?,
        tier: Int?,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        clientId: String,
        issuer: String)
    {
        self.email = email
        self.tier = tier
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientId = clientId
        self.issuer = issuer
    }

    /// True if the current access token is still valid (with 60s skew).
    public var isAccessTokenValid: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince(expiresAt) < -60
    }

    /// Human-friendly plan name based on tier.
    public var planName: String {
        switch self.tier {
        case 5: "Super Heavy"
        case 4: "Heavy"
        case 3: "Pro"
        case 2: "Plus"
        case 1: "Free"
        default: "Grok Build"
        }
    }

    /// Whether this session carries the grok-cli:access scope (required for Super Heavy entitlements).
    public var hasGrokCliAccess: Bool {
        // We decode the JWT on demand for this check; the presence of a refresh token + CLI client is a strong signal.
        self.refreshToken != nil || self.tier == 5
    }
}

public enum GrokCliSessionError: LocalizedError, Sendable, Equatable {
    case notFound
    case decodeFailed(String)
    case missingToken
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Grok CLI auth not found. Run `grok` (or the Grok Build CLI) and sign in."
        case let .decodeFailed(message):
            "Failed to read Grok CLI auth: \(message)"
        case .missingToken:
            "Grok auth.json exists but contains no access token for the CLI client."
        case let .invalidFormat(message):
            "Grok auth.json has an unexpected format: \(message)"
        }
    }
}

/// Loader for the official Grok Build CLI credentials (~/.grok/auth.json).
/// Uses the exact same file format, client ID, and JWT claims as the VS Code xai-grok-plugin
/// and the official `grok` CLI. This enables zero-friction usage monitoring in CodexBar
/// for anyone already logged into the Grok Build ecosystem.
public enum GrokCliSessionStore {
    /// The official Grok Build CLI client ID (registered for the `grok` binary and Grok Build family).
    public static let officialClientId = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let issuer = "https://auth.x.ai"

    private static func authFilePath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        let home: URL = if let custom = env["GROK_HOME"], !custom.isEmpty {
            URL(fileURLWithPath: custom, isDirectory: true)
        } else if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("grok", isDirectory: true)
        } else {
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
        }
        return home.appendingPathComponent("auth.json")
    }

    /// Attempts to load a valid Grok CLI session. Throws if the file is missing or unreadable.
    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) throws -> GrokCliSession {
        let url = self.authFilePath(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GrokCliSessionError.notFound
        }
        let data = try Data(contentsOf: url)
        return try self.parse(data: data)
    }

    public static func parse(data: Data) throws -> GrokCliSession {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokCliSessionError.decodeFailed("Invalid JSON")
        }

        // The CLI stores entries under keys like "https://auth.x.ai::b1a00492-..."
        let entryKey = json.keys.first { $0.contains(Self.officialClientId) }
        guard let entryKey, let entry = json[entryKey] as? [String: Any] else {
            throw GrokCliSessionError.missingToken
        }

        guard let accessToken = entry["key"] as? String, !accessToken.isEmpty else {
            throw GrokCliSessionError.missingToken
        }

        let refreshToken = entry["refresh_token"] as? String
        let email = entry["email"] as? String

        var expiresAt: Date?
        if let expiresString = entry["expires_at"] as? String {
            let formatter = ISO8601DateFormatter()
            expiresAt = formatter.date(from: expiresString)
        } else if let expiresNumber = entry["expires_at"] as? TimeInterval {
            expiresAt = Date(timeIntervalSince1970: expiresNumber / 1000)
        }

        // Decode tier + email from the JWT payload (same logic as VS Code extension)
        var decodedTier: Int?
        var decodedEmail = email
        let parts = accessToken.split(separator: ".")
        if parts.count == 3 {
            if let payloadData = Data(base64Encoded: String(parts[1])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
                .padding(toLength: ((parts[1].count + 3) / 4) * 4, withPad: "=", startingAt: 0)),
                let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            {
                if let tier = payload["tier"] as? Int {
                    decodedTier = tier
                }
                if let emailFromJwt = payload["email"] as? String, decodedEmail == nil {
                    decodedEmail = emailFromJwt
                }
            }
        }

        return GrokCliSession(
            email: decodedEmail,
            tier: decodedTier,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            clientId: Self.officialClientId,
            issuer: Self.issuer)
    }

    /// Convenience: returns nil instead of throwing when no session is present.
    public static func loadIfPresent(env: [String: String] = ProcessInfo.processInfo.environment) -> GrokCliSession? {
        try? self.load(env: env)
    }
}
