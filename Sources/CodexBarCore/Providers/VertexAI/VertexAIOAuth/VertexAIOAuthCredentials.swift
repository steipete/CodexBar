import Foundation

public struct VertexAIOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let clientId: String
    public let clientSecret: String
    public let projectId: String?
    public let email: String?
    public let expiryDate: Date?

    public init(
        accessToken: String,
        refreshToken: String,
        clientId: String,
        clientSecret: String,
        projectId: String?,
        email: String?,
        expiryDate: Date?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.projectId = projectId
        self.email = email
        self.expiryDate = expiryDate
    }

    public var needsRefresh: Bool {
        guard let expiryDate else { return true }
        // Refresh 5 minutes before expiry
        return Date().addingTimeInterval(300) > expiryDate
    }
}

public enum VertexAIOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case decodeFailed(String)
    case missingTokens
    case missingClientCredentials

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "gcloud credentials not found. Run `gcloud auth application-default login` to authenticate."
        case let .decodeFailed(message):
            "Failed to decode gcloud credentials: \(message)"
        case .missingTokens:
            "gcloud credentials exist but contain no tokens."
        case .missingClientCredentials:
            "gcloud credentials missing client ID or secret."
        }
    }
}

public enum VertexAIOAuthCredentialsStore {
    private static var credentialsFilePath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // gcloud application default credentials location
        if let configDir = ProcessInfo.processInfo.environment["CLOUDSDK_CONFIG"]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !configDir.isEmpty
        {
            return URL(fileURLWithPath: configDir)
                .appendingPathComponent("application_default_credentials.json")
        }
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("gcloud")
            .appendingPathComponent("application_default_credentials.json")
    }

    private static var projectFilePath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let configDir = ProcessInfo.processInfo.environment["CLOUDSDK_CONFIG"]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !configDir.isEmpty
        {
            return URL(fileURLWithPath: configDir)
                .appendingPathComponent("configurations")
                .appendingPathComponent("config_default")
        }
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("gcloud")
            .appendingPathComponent("configurations")
            .appendingPathComponent("config_default")
    }

    public static func load() throws -> VertexAIOAuthCredentials {
        let url = self.credentialsFilePath
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VertexAIOAuthCredentialsError.notFound
        }

        let data = try Data(contentsOf: url)
        return try self.parse(data: data)
    }

    public static func parse(data: Data) throws -> VertexAIOAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VertexAIOAuthCredentialsError.decodeFailed("Invalid JSON")
        }

        // Check for service account credentials
        if json["client_email"] is String,
           json["private_key"] is String
        {
            // Service account - use JWT for access token (simplified)
            throw VertexAIOAuthCredentialsError.decodeFailed(
                "Service account credentials not yet supported. Use `gcloud auth application-default login`.")
        }

        // User credentials from gcloud auth application-default login
        guard let clientId = json["client_id"] as? String,
              let clientSecret = json["client_secret"] as? String
        else {
            throw VertexAIOAuthCredentialsError.missingClientCredentials
        }

        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw VertexAIOAuthCredentialsError.missingTokens
        }

        // Access token may not be present in the file; we'll need to refresh
        let accessToken = json["access_token"] as? String ?? ""

        // Try to get project ID from gcloud config
        let projectId = Self.loadProjectId()

        // Try to extract email from ID token if present
        let email = Self.extractEmailFromIdToken(json["id_token"] as? String)

        // Parse expiry if present
        var expiryDate: Date?
        if let expiryStr = json["token_expiry"] as? String {
            let formatter = ISO8601DateFormatter()
            expiryDate = formatter.date(from: expiryStr)
        }

        return VertexAIOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            clientId: clientId,
            clientSecret: clientSecret,
            projectId: projectId,
            email: email,
            expiryDate: expiryDate)
    }

    public static func save(_ credentials: VertexAIOAuthCredentials) throws {
        // We don't modify gcloud's credentials file; just cache the access token in memory
        // The refresh happens on each app launch if needed
    }

    private static func loadProjectId() -> String? {
        let configPath = self.projectFilePath
        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return nil
        }

        // Parse INI-style config for project
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("project") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Try environment variable
        return ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
            ?? ProcessInfo.processInfo.environment["GCLOUD_PROJECT"]
            ?? ProcessInfo.processInfo.environment["CLOUDSDK_CORE_PROJECT"]
    }

    private static func extractEmailFromIdToken(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }

        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return json["email"] as? String
    }
}
