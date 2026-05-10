import Foundation

public struct AntigravityOAuthCredentials: Codable, Sendable, Equatable {
    public var accessToken: String?
    public var refreshToken: String?
    public var expiryDateMilliseconds: Double?
    public var idToken: String?
    public var email: String?
    public var projectID: String?
    public var clientID: String?
    public var clientSecret: String?

    public init(
        accessToken: String?,
        refreshToken: String?,
        expiryDate: Date?,
        idToken: String? = nil,
        email: String? = nil,
        projectID: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDateMilliseconds = expiryDate.map { $0.timeIntervalSince1970 * 1000 }
        self.idToken = idToken
        self.email = email
        self.projectID = projectID
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var expiryDate: Date? {
        guard let expiryDateMilliseconds else { return nil }
        return Date(timeIntervalSince1970: expiryDateMilliseconds / 1000)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken =
            try container.decodeIfPresent(String.self, forKey: .accessTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .accessTokenCamel)
        self.refreshToken =
            try container.decodeIfPresent(String.self, forKey: .refreshTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .refreshTokenCamel)
        self.idToken =
            try container.decodeIfPresent(String.self, forKey: .idTokenSnake)
            ?? container.decodeIfPresent(String.self, forKey: .idTokenCamel)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.projectID =
            try container.decodeIfPresent(String.self, forKey: .projectIDSnake)
            ?? container.decodeIfPresent(String.self, forKey: .projectIDCamel)
        self.clientID =
            try container.decodeIfPresent(String.self, forKey: .clientIDSnake)
            ?? container.decodeIfPresent(String.self, forKey: .clientIDCamel)
        self.clientSecret =
            try container.decodeIfPresent(String.self, forKey: .clientSecretSnake)
            ?? container.decodeIfPresent(String.self, forKey: .clientSecretCamel)

        if let expiryDateMilliseconds = try container.decodeIfPresent(Double.self, forKey: .expiryDateSnake)
            ?? container.decodeIfPresent(Double.self, forKey: .expiresAtCamel)
        {
            self.expiryDateMilliseconds = expiryDateMilliseconds
        } else if let expiryDateMilliseconds = try container.decodeIfPresent(Int.self, forKey: .expiryDateSnake)
            ?? container.decodeIfPresent(Int.self, forKey: .expiresAtCamel)
        {
            self.expiryDateMilliseconds = Double(expiryDateMilliseconds)
        } else {
            self.expiryDateMilliseconds = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.accessToken, forKey: .accessTokenSnake)
        try container.encodeIfPresent(self.refreshToken, forKey: .refreshTokenSnake)
        try container.encodeIfPresent(self.expiryDateMilliseconds, forKey: .expiryDateSnake)
        try container.encodeIfPresent(self.idToken, forKey: .idTokenSnake)
        try container.encodeIfPresent(self.email, forKey: .email)
        try container.encodeIfPresent(self.projectID, forKey: .projectIDSnake)
        try container.encodeIfPresent(self.clientID, forKey: .clientIDSnake)
        try container.encodeIfPresent(self.clientSecret, forKey: .clientSecretSnake)
    }

    enum CodingKeys: String, CodingKey {
        case accessTokenSnake = "access_token"
        case accessTokenCamel = "accessToken"
        case refreshTokenSnake = "refresh_token"
        case refreshTokenCamel = "refreshToken"
        case expiryDateSnake = "expiry_date"
        case expiresAtCamel = "expiresAt"
        case idTokenSnake = "id_token"
        case idTokenCamel = "idToken"
        case email
        case projectIDSnake = "project_id"
        case projectIDCamel = "projectId"
        case clientIDSnake = "client_id"
        case clientIDCamel = "clientId"
        case clientSecretSnake = "client_secret"
        case clientSecretCamel = "clientSecret"
    }
}

public struct AntigravityOAuthClient: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public enum AntigravityOAuthConfig {
    public static var configuredClientID: String? {
        let value = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static var configuredClientSecret: String? {
        let value = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    public static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    public static let missingCredentialsMessage =
        """
        Antigravity OAuth client is not configured. Install Antigravity.app or set \
        ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET before logging in.
        """

    public static func resolvedClient() -> AntigravityOAuthClient? {
        if let client = environmentClient() {
            return client
        }
        return Self.discoverClientFromInstalledApp()
    }

    private static func environmentClient() -> AntigravityOAuthClient? {
        guard let clientID = configuredClientID,
              let clientSecret = configuredClientSecret
        else {
            return nil
        }
        return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
    }

    private static func discoverClientFromInstalledApp(fileManager: FileManager = .default) -> AntigravityOAuthClient? {
        for url in self.candidateAppMainJSURLs(fileManager: fileManager)
            where fileManager.fileExists(atPath: url.path)
        {
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let client = Self.parseClient(fromMainJS: content)
            else {
                continue
            }
            return client
        }
        return nil
    }

    private static func candidateAppMainJSURLs(fileManager: FileManager) -> [URL] {
        let bundleRelativePath = "Antigravity.app/Contents/Resources/app/out/main.js"
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(bundleRelativePath),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(bundleRelativePath),
        ]
    }

    private static func parseClient(fromMainJS content: String) -> AntigravityOAuthClient? {
        let marker = "vs/platform/cloudCode/common/oauthClient.js"
        let searchStart = content.range(of: marker)?.lowerBound ?? content.startIndex
        let searchEnd = content.index(searchStart, offsetBy: 4000, limitedBy: content.endIndex) ?? content.endIndex
        let haystack = String(content[searchStart..<searchEnd])

        guard let clientID = Self.firstMatch(
            pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#,
            in: haystack),
            let clientSecret = Self.firstMatch(
                pattern: #"GOCSPX-[A-Za-z0-9_-]+"#,
                in: haystack)
        else {
            return nil
        }

        return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text)
        else {
            return nil
        }
        return String(text[swiftRange])
    }
}

public struct AntigravityOAuthCredentialsStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> AntigravityOAuthCredentials? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return nil }
        let data = try Data(contentsOf: self.fileURL)
        return try JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
    }

    public func save(_ credentials: AntigravityOAuthCredentials) throws {
        let data = try JSONEncoder.antigravityCredentials.encode(credentials)
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: self.fileURL, options: [.atomic])
        try self.applySecurePermissionsIfNeeded()
    }

    public func deleteIfPresent() throws {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return }
        try self.fileManager.removeItem(at: self.fileURL)
    }

    public static func defaultDirectoryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        self.defaultDirectoryURL(home: home)
            .appendingPathComponent("oauth_creds.json")
    }

    private func applySecurePermissionsIfNeeded() throws {
        #if os(macOS) || os(Linux)
        try self.fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: self.fileURL.path)
        #endif
    }
}

extension JSONEncoder {
    fileprivate static let antigravityCredentials: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
