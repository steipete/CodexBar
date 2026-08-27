import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum CodexOAuthCredentialSource: String, Equatable, Sendable {
    case codexHome
    case legacyCodexHome
    case openCode

    var canPersistRefresh: Bool {
        self == .codexHome
    }
}

public struct CodexOAuthCredentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?
    public let expiresAt: Date?
    public let source: CodexOAuthCredentialSource
    public let isAPIKey: Bool

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        lastRefresh: Date?,
        expiresAt: Date? = nil,
        source: CodexOAuthCredentialSource = .codexHome,
        isAPIKey: Bool = false)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
        self.expiresAt = expiresAt
        self.source = source
        self.isAPIKey = isAPIKey
    }

    public var needsRefresh: Bool {
        if self.isAPIKey {
            return false
        }
        if let expiresAt {
            let refreshWindow: TimeInterval = self.source == .codexHome ? 5 * 60 : 60
            return expiresAt.timeIntervalSinceNow <= refreshWindow
        }
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

public enum CodexOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case unreadable
    case decodeFailed(String)
    case missingTokens
    case nativeRefreshRequired
    case readOnlySource

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex auth.json not found. Run `codex login` to sign in."
        case .unreadable:
            "Codex auth.json could not be read. Check its permissions or run `codex login` to sign in again."
        case let .decodeFailed(message):
            "Failed to decode Codex credentials: \(message)"
        case .missingTokens:
            "Codex auth.json exists but contains no tokens."
        case .nativeRefreshRequired:
            "Codex auth.json needs refresh. CodexBar will retry through the Codex CLI; "
                + "run `codex login` if recovery fails."
        case .readOnlySource:
            "This external Codex credential source is stale and read-only. "
                + "Sign in again with its owning app or run `codex login` to create fresh native credentials."
        }
    }
}

public enum CodexOAuthCredentialsStore {
    /// Chrono 0.4 accepts UTC timestamps from year -262143 through year 262142.
    private static let codexJWTExpirationRange: ClosedRange<Int64> =
        -8_334_601_228_800...8_210_266_876_799

    private static func authFilePath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) -> URL
    {
        let home =
            if self.nonEmpty(env["CODEX_HOME"]) != nil {
                CodexHomeScope.ambientHomeURL(env: env, fileManager: fileManager)
            } else {
                (homeDirectory ?? fileManager.homeDirectoryForCurrentUser)
                    .appendingPathComponent(".codex", isDirectory: true)
            }
        return
            home
                .appendingPathComponent("auth.json")
    }

    public static func load(
        env: [String: String] = ProcessInfo.processInfo
            .environment) throws -> CodexOAuthCredentials
    {
        try self.loadNative(env: env, homeDirectory: nil)
    }

    public static func loadOAuthTokens(
        env: [String: String] = ProcessInfo.processInfo
            .environment) throws -> CodexOAuthCredentials
    {
        try self.parseOAuthTokens(data: self.readAuthData(env: env), source: .codexHome)
    }

    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        try self.parse(data: data, source: .codexHome)
    }

    public static func loadPAT(
        env: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexPATCredentials
    {
        try self.parsePAT(data: self.readAuthData(env: env), source: .codexHome)
    }

    /// Load a PAT from the scoped `CODEX_HOME` when that home has one, otherwise from ambient
    /// `~/.codex`. Managed and fail-closed homes always use ambient.
    public static func loadPATResolvingScopedHome(
        env: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexPATCredentials
    {
        try self.loadPAT(env: CodexPATFetchStrategy.credentialEnvironment(env))
    }

    public static func parsePAT(data: Data) throws -> CodexPATCredentials {
        try self.parsePAT(data: data, source: .codexHome)
    }

    /// Resolve a credential for a usage probe without changing any source file.
    ///
    /// The ambient Codex home wins. External sources are opt-in because reading another
    /// application's OAuth file is a provider-auth and privacy boundary.
    public static func loadForUsage(
        env: [String: String] = ProcessInfo.processInfo.environment,
        allowExternalSources: Bool = false) throws -> CodexOAuthCredentials
    {
        try self.loadForUsage(env: env, homeDirectory: nil, allowExternalSources: allowExternalSources)
    }

    private static func loadForUsage(
        env: [String: String],
        homeDirectory: URL?,
        allowExternalSources: Bool) throws -> CodexOAuthCredentials
    {
        guard CodexCredentialFileAccess.permits(self.authFilePath(env: env, homeDirectory: homeDirectory)) else {
            throw CodexOAuthCredentialsError.notFound
        }
        do {
            return try self.loadNative(env: env, homeDirectory: homeDirectory)
        } catch let nativeError as CodexOAuthCredentialsError {
            guard allowExternalSources,
                  self.shouldTryExternalFallback(nativeError, env: env)
            else { throw nativeError }
            if let legacy = try? self.loadLegacyCodexCredentials(homeDirectory: homeDirectory) {
                return legacy
            }
            if let openCode = try? self.loadOpenCodeCredentials(env: env, homeDirectory: homeDirectory) {
                return openCode
            }
            throw nativeError
        }
    }

    private static func loadNative(
        env: [String: String],
        homeDirectory: URL?) throws -> CodexOAuthCredentials
    {
        let data = try self.readAuthData(env: env, homeDirectory: homeDirectory)
        return try self.parse(data: data, source: .codexHome)
    }

    private static func parse(
        data: Data,
        source: CodexOAuthCredentialSource) throws -> CodexOAuthCredentials
    {
        let json = try self.decodeObject(data: data)

        if let apiKeyCredentials = Self.apiKeyCredentials(in: json, source: source) {
            return apiKeyCredentials
        }

        if let tokenCredentials = Self.tokenCredentials(in: json, source: source) {
            return tokenCredentials
        }

        throw CodexOAuthCredentialsError.missingTokens
    }

    private static func parsePAT(
        data: Data,
        source: CodexOAuthCredentialSource) throws -> CodexPATCredentials
    {
        let json = try self.decodeObject(data: data)
        guard let credentials = self.patCredentials(in: json, source: source) else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        return credentials
    }

    private static func patCredentials(
        in json: [String: Any],
        source: CodexOAuthCredentialSource) -> CodexPATCredentials?
    {
        let token =
            self.nonEmpty(json["personal_access_token"] as? String)
            ?? self.nonEmpty(json["personalAccessToken"] as? String)
        guard let token else { return nil }
        return CodexPATCredentials(token: token, source: source)
    }

    private static func readAuthData(
        env: [String: String],
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) throws -> Data
    {
        let url = self.authFilePath(env: env, fileManager: fileManager, homeDirectory: homeDirectory)
        return try self.readAuthData(at: url)
    }

    private static func readAuthData(at url: URL) throws -> Data {
        guard CodexCredentialFileAccess.permits(url) else { throw CodexOAuthCredentialsError.notFound }
        do {
            // Read once instead of checking existence first. Codex publishes auth.json atomically,
            // so a single read avoids a TOCTOU window and lets us distinguish a missing file from a
            // transiently unreadable/partially published one without logging credentials.
            return try CodexCredentialFileAccess.read(at: url, options: [.mappedIfSafe])
        } catch {
            let nsError = error as NSError
            let missingFile =
                (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileReadNoSuchFile.rawValue)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
            throw missingFile ? CodexOAuthCredentialsError.notFound : CodexOAuthCredentialsError.unreadable
        }
    }

    private static func decodeObject(data: Data) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
            }
            return json
        } catch let error as CodexOAuthCredentialsError {
            throw error
        } catch {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }
    }

    private static func tokenCredentials(
        in json: [String: Any],
        source: CodexOAuthCredentialSource) -> CodexOAuthCredentials?
    {
        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = stringValue(
                  in: tokens,
                  snakeCaseKey: "access_token",
                  camelCaseKey: "accessToken"),
              let refreshToken = stringValue(
                  in: tokens,
                  snakeCaseKey: "refresh_token",
                  camelCaseKey: "refreshToken"),
              !accessToken.isEmpty
        else {
            return nil
        }

        let idToken = Self.stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken")
        let accountId =
            Self.nonEmpty(
                Self.stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"))
            ?? Self.accountIDFromJWT(idToken: idToken, accessToken: accessToken)
        let lastRefresh = Self.parseLastRefresh(from: json["last_refresh"])
        let expiresAt = source == .codexHome ? Self.expirationFromJWT(accessToken: accessToken) : nil

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            lastRefresh: lastRefresh,
            expiresAt: expiresAt,
            source: source)
    }

    private static func apiKeyCredentials(
        in json: [String: Any],
        source: CodexOAuthCredentialSource) -> CodexOAuthCredentials?
    {
        guard let apiKey = json["OPENAI_API_KEY"] as? String,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return CodexOAuthCredentials(
            accessToken: apiKey,
            refreshToken: "",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil,
            source: source,
            isAPIKey: true)
    }

    public static func save(
        _ credentials: CodexOAuthCredentials,
        env: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard credentials.source.canPersistRefresh else {
            throw CodexOAuthCredentialsError.readOnlySource
        }
        let url = self.authFilePath(env: env)
        guard CodexCredentialFileAccess.permits(url) else { throw CodexOAuthCredentialsError.notFound }
        if try CodexCredentialFileAccess.substituteWriteForTesting(at: url) { return }

        var json: [String: Any] = [:]
        if let data = try? CodexCredentialFileAccess.read(at: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken,
        ]
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        }

        json["tokens"] = tokens
        // Persist the timestamp that belongs to the credential material. A metadata-only caller
        // must not make an old access token look freshly rotated by stamping the current time.
        if let lastRefresh = credentials.lastRefresh {
            json["last_refresh"] = ISO8601DateFormatter().string(from: lastRefresh)
        }

        let data = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try CodexCredentialFileAccess.createDirectory(forCredentialAt: url)
        try CredentialFileWriter.writePrivate(data, to: url)
    }

    private static func shouldTryExternalFallback(
        _ error: CodexOAuthCredentialsError,
        env: [String: String]) -> Bool
    {
        guard self.nonEmpty(env["CODEX_HOME"]) == nil else { return false }
        switch error {
        // A present-but-unreadable or malformed native file is an identity boundary, not an
        // invitation to silently substitute another application's session.
        case .notFound:
            return true
        case .unreadable, .decodeFailed, .missingTokens, .nativeRefreshRequired, .readOnlySource:
            return false
        }
    }

    private static func loadLegacyCodexCredentials(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) throws -> CodexOAuthCredentials
    {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let url =
            home
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
                .appendingPathComponent("auth.json")
        return try self.parseOAuthTokens(
            data: self.readAuthData(at: url),
            source: .legacyCodexHome)
    }

    private static func parseOAuthTokens(
        data: Data,
        source: CodexOAuthCredentialSource) throws -> CodexOAuthCredentials
    {
        let json = try self.decodeObject(data: data)
        guard let credentials = self.tokenCredentials(in: json, source: source) else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        return credentials
    }

    private static func loadOpenCodeCredentials(
        env: [String: String],
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil) throws -> CodexOAuthCredentials
    {
        let root: URL =
            if let configured = self.nonEmpty(env["XDG_DATA_HOME"]),
            let normalized = CodexHomeScope.normalizedHomePath(configured, fileManager: fileManager) {
                URL(fileURLWithPath: normalized, isDirectory: true)
            } else {
                (homeDirectory ?? fileManager.homeDirectoryForCurrentUser)
                    .appendingPathComponent(".local", isDirectory: true)
                    .appendingPathComponent("share", isDirectory: true)
            }
        // Provider-specific by design: OpenCode stores the OpenAI OAuth entry under its own data directory.
        let url =
            root
                .appendingPathComponent("opencode", isDirectory: true)
                .appendingPathComponent("auth.json")
        return try self.parseOpenCode(data: self.readAuthData(at: url))
    }

    private static func parseOpenCode(data: Data) throws -> CodexOAuthCredentials {
        let json = try self.decodeObject(data: data)
        guard let auth = json["openai"] as? [String: Any],
              let type = self.nonEmpty(auth["type"] as? String),
              type.caseInsensitiveCompare("oauth") == .orderedSame,
              let access = self.nonEmpty(auth["access"] as? String)
        else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        return CodexOAuthCredentials(
            accessToken: access,
            refreshToken: self.nonEmpty(auth["refresh"] as? String) ?? "",
            idToken: nil,
            accountId: self.nonEmpty(auth["accountId"] as? String),
            lastRefresh: nil,
            expiresAt: self.parseEpochMilliseconds(auth["expires"]),
            source: .openCode)
    }

    private static func parseEpochMilliseconds(_ raw: Any?) -> Date? {
        guard let number = raw as? NSNumber else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String)
        -> String?
    {
        if let value = dictionary[snakeCaseKey] as? String, !value.isEmpty {
            return value
        }
        if let value = dictionary[camelCaseKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    /// Codex auth files normally persist `tokens.account_id`, but older and partially migrated
    /// files can omit it. OpenAI also carries the identity in JWT claims; recover it without
    /// treating a malformed or opaque token as a credential-read failure.
    private static func accountIDFromJWT(idToken: String?, accessToken: String?) -> String? {
        for token in [idToken, accessToken].compactMap(\.self) {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var encoded = String(parts[1])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let payloadData = Data(base64Encoded: encoded),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            else { continue }

            if let accountID = Self.nonEmpty(payload["chatgpt_account_id"] as? String) {
                return accountID
            }
            if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
               let accountID = Self.nonEmpty(auth["chatgpt_account_id"] as? String)
            {
                return accountID
            }
            if let organizations = payload["organizations"] as? [[String: Any]],
               let accountID =
               organizations
                   .compactMap({ Self.nonEmpty($0["id"] as? String) })
                   .first
            {
                return accountID
            }
        }
        return nil
    }

    /// Best-effort scheduling hint only: the service still authenticates the unchanged bearer token.
    private static func expirationFromJWT(accessToken: String) -> Date? {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payloadData = Data(base64Encoded: encoded),
              let expiration = Self.integerExpirationClaim(in: payloadData),
              Self.codexJWTExpirationRange.contains(expiration)
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiration))
    }

    private static func integerExpirationClaim(in data: Data) -> Int64? {
        guard let payload = String(data: data, encoding: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let lexer = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|[{}\[\]:,]|[^\s{}\[\]:,]+"#)
        else { return nil }

        // Foundation validates JSON above. Inspect raw tokens only to retain integer spelling:
        // NSNumber/JSONDecoder can normalize 1.0 or 1e0 to integers differently across platforms.
        let tokens = lexer.matches(in: payload, range: NSRange(payload.startIndex..., in: payload))
            .compactMap { Range($0.range, in: payload).map { String(payload[$0]) } }
        var depth = 0
        var expiration: Int64?
        for (index, token) in tokens.enumerated() {
            switch token {
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default:
                guard depth == 1, index + 2 < tokens.count, tokens[index + 1] == ":",
                      (try? JSONDecoder().decode(String.self, from: Data(token.utf8))) == "exp"
                else { continue }
                // Duplicate claims are ambiguous; keep the existing age fallback instead.
                guard expiration == nil, let integer = Int64(tokens[index + 2]) else { return nil }
                expiration = integer
            }
        }
        return expiration
    }
}

#if DEBUG
extension CodexOAuthCredentialsStore {
    static func _authFileURLForTesting(env: [String: String]) -> URL {
        self.authFilePath(env: env)
    }

    static func _loadForUsageForTesting(
        env: [String: String],
        homeDirectory: URL,
        allowExternalSources: Bool = false) throws -> CodexOAuthCredentials
    {
        let scope = (CodexCredentialFileAccess.fixtureScope ?? .init()).including(root: homeDirectory)
        return try CodexCredentialFileAccess.withFixtureScope(scope) {
            try self.loadForUsage(
                env: env,
                homeDirectory: homeDirectory,
                allowExternalSources: allowExternalSources)
        }
    }

    static func _parseOpenCodeForTesting(data: Data) throws -> CodexOAuthCredentials {
        try self.parseOpenCode(data: data)
    }

    static func _writePrivateFileForTesting(
        _ data: Data,
        to url: URL,
        beforePublish: @escaping (URL) throws -> Void) throws
    {
        guard CodexCredentialFileAccess.permits(url) else { throw CodexOAuthCredentialsError.notFound }
        try CredentialFileWriter.writePrivate(data, to: url, beforePublish: beforePublish)
    }
}
#endif
