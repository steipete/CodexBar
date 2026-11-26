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
    #if DEBUG
    @TaskLocal static var gcloudAccessTokenOverrideForTesting: (@Sendable ([String: String]) async throws -> String)?
    #endif

    private struct ServiceAccountMetadata {
        let email: String
        let projectId: String?
    }

    private static func credentialsFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let path = environment["GOOGLE_APPLICATION_CREDENTIALS"]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !path.isEmpty
        {
            return URL(fileURLWithPath: path)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        // gcloud application default credentials location
        if let configDir = environment["CLOUDSDK_CONFIG"]?.trimmingCharacters(
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

    private static func projectFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let configDir = environment["CLOUDSDK_CONFIG"]?.trimmingCharacters(
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

    public static func hasCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let url = self.credentialsFilePath(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? self.parseJSONObject(data: data)
        else {
            return false
        }

        if self.parseServiceAccountMetadata(json: json) != nil {
            return true
        }

        return (try? self.parseUserCredentials(json: json, environment: environment)) != nil
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projectIDOverride: String? = nil) throws -> VertexAIOAuthCredentials
    {
        let url = self.credentialsFilePath(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VertexAIOAuthCredentialsError.notFound
        }

        let data = try Data(contentsOf: url)
        return try self.parse(
            data: data,
            environment: environment,
            projectIDOverride: projectIDOverride)
    }

    public static func loadForFetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projectIDOverride: String? = nil) async throws -> VertexAIOAuthCredentials
    {
        let url = self.credentialsFilePath(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VertexAIOAuthCredentialsError.notFound
        }

        let data = try Data(contentsOf: url)
        let json = try self.parseJSONObject(data: data)
        if let serviceAccount = self.parseServiceAccountMetadata(json: json) {
            let token = try await self.printAccessToken(environment: environment)
            let resolvedProjectID = Self.normalizedProjectID(projectIDOverride)
                ?? Self.normalizedProjectID(environment["CODEXBAR_VERTEX_PROJECT_ID"])
                ?? serviceAccount.projectId
                ?? self.loadProjectId(environment: environment, projectIDOverride: nil)
            return VertexAIOAuthCredentials(
                accessToken: token,
                refreshToken: "",
                clientId: "",
                clientSecret: "",
                projectId: resolvedProjectID,
                email: serviceAccount.email,
                expiryDate: Date().addingTimeInterval(50 * 60))
        }

        return try self.parseUserCredentials(
            json: json,
            environment: environment,
            projectIDOverride: projectIDOverride)
    }

    public static func resolveValidCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projectIDOverride: String? = nil,
        refreshTransport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        persistRefreshed: Bool = true) async throws -> VertexAIOAuthCredentials
    {
        var credentials = try await self.loadForFetch(
            environment: environment,
            projectIDOverride: projectIDOverride)
        if credentials.needsRefresh {
            credentials = try await VertexAITokenRefresher.refresh(credentials, session: refreshTransport)
            if persistRefreshed {
                try self.save(credentials)
            }
        }
        return credentials
    }

    public static func parse(data: Data) throws -> VertexAIOAuthCredentials {
        try self.parse(data: data, environment: ProcessInfo.processInfo.environment, projectIDOverride: nil)
    }

    public static func parse(
        data: Data,
        environment: [String: String],
        projectIDOverride: String? = nil) throws -> VertexAIOAuthCredentials
    {
        let json = try self.parseJSONObject(data: data)
        return try self.parseUserCredentials(
            json: json,
            environment: environment,
            projectIDOverride: projectIDOverride)
    }

    private static func parseJSONObject(data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VertexAIOAuthCredentialsError.decodeFailed("Invalid JSON")
        }
        return json
    }

    private static func parseUserCredentials(
        json: [String: Any],
        environment: [String: String],
        projectIDOverride: String? = nil) throws -> VertexAIOAuthCredentials
    {
        // Check for service account credentials
        if self.parseServiceAccountMetadata(json: json) != nil {
            throw VertexAIOAuthCredentialsError.decodeFailed(
                "Service account credentials require `gcloud auth application-default print-access-token`.")
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

        // Try to get project ID from override, env, or gcloud config
        let projectId = Self.loadProjectId(environment: environment, projectIDOverride: projectIDOverride)

        let email = VertexAIIDToken.email(from: json["id_token"] as? String)

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

    /// Compatibility no-op; gcloud owns credential persistence.
    public static func save(_: VertexAIOAuthCredentials) throws {}

    private static func parseServiceAccountMetadata(json: [String: Any]) -> ServiceAccountMetadata? {
        guard let email = (json["client_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty,
              let privateKey = (json["private_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !privateKey.isEmpty
        else {
            return nil
        }

        let projectId = (json["project_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ServiceAccountMetadata(
            email: email,
            projectId: projectId?.isEmpty == false ? projectId : nil)
    }

    private static func printAccessToken(environment: [String: String]) async throws -> String {
        #if DEBUG
        if let override = self.gcloudAccessTokenOverrideForTesting {
            let token = try await override(environment)
            return try self.cleanAccessToken(token)
        }
        #endif

        let env = TTYCommandRunner.enrichedEnvironment(baseEnv: environment)
        let result = try await SubprocessRunner.run(
            binary: "/usr/bin/env",
            arguments: ["gcloud", "auth", "application-default", "print-access-token"],
            environment: env,
            timeout: 20,
            label: "vertexai-gcloud-adc-token")
        return try self.cleanAccessToken(result.stdout)
    }

    private static func cleanAccessToken(_ token: String) throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VertexAIOAuthCredentialsError.missingTokens
        }
        return trimmed
    }

    private static func normalizedProjectID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func loadProjectId(
        environment: [String: String],
        projectIDOverride: String? = nil) -> String?
    {
        if let override = normalizedProjectID(projectIDOverride) {
            return override
        }
        if let envOverride = Self.normalizedProjectID(environment["CODEXBAR_VERTEX_PROJECT_ID"]) {
            return envOverride
        }

        let configPath = self.projectFilePath(environment: environment)
        if let content = try? String(contentsOf: configPath, encoding: .utf8),
           let parsedProject = Self.parseConfigProjectID(content)
        {
            return parsedProject
        }

        // Try environment variable
        return Self.normalizedProjectID(environment["GOOGLE_CLOUD_PROJECT"])
            ?? Self.normalizedProjectID(environment["GCLOUD_PROJECT"])
            ?? Self.normalizedProjectID(environment["CLOUDSDK_CORE_PROJECT"])
    }

    private static func parseConfigProjectID(_ content: String) -> String? {
        var currentSection: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                currentSection = inner.lowercased()
                continue
            }
            guard currentSection == nil || currentSection == "core" else { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "project" else { continue }
            let value = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
