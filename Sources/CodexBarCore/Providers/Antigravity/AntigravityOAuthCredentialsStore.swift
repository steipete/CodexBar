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

    static func discoverClientFromInstalledApp(
        applicationRoots: [URL]? = nil,
        fileManager: FileManager = .default) -> AntigravityOAuthClient?
    {
        for url in self.candidateOAuthClientArtifactURLs(
            applicationRoots: applicationRoots,
            fileManager: fileManager)
            where fileManager.fileExists(atPath: url.path)
        {
            guard let data = try? Data(contentsOf: url),
                  let client = Self.parseClient(fromInstalledArtifactData: data)
            else {
                continue
            }
            return client
        }
        return nil
    }

    static func candidateOAuthClientArtifactURLs(
        applicationRoots: [URL]? = nil,
        fileManager: FileManager = .default) -> [URL]
    {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        let applicationRoots = applicationRoots ?? roots
        let appBundleURLs = self.candidateAntigravityAppBundleURLs(
            applicationRoots: applicationRoots,
            fileManager: fileManager)
        let relativePaths = [
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos",
        ]
        return appBundleURLs.flatMap { bundleURL in
            relativePaths.map { bundleURL.appendingPathComponent($0) }
        }
    }

    private static func candidateAntigravityAppBundleURLs(
        applicationRoots: [URL],
        fileManager: FileManager) -> [URL]
    {
        var urls: [URL] = []

        for root in applicationRoots {
            urls.append(root.appendingPathComponent("Antigravity.app", isDirectory: true))

            let appURLs = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for appURL in appURLs where appURL.pathExtension == "app" {
                guard self.isAntigravityAppBundle(appURL) else { continue }
                urls.append(appURL)
            }
        }

        var seen = Set<String>()
        return urls.filter { url in
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func isAntigravityAppBundle(_ url: URL) -> Bool {
        switch Bundle(url: url)?.bundleIdentifier {
        case "com.google.antigravity", "com.google.antigravity-ide":
            true
        default:
            false
        }
    }

    static func parseClient(fromInstalledArtifactData data: Data) -> AntigravityOAuthClient? {
        if let content = String(data: data, encoding: .utf8),
           let client = parseClient(fromInstalledArtifactText: content)
        {
            return client
        }

        let clientIDs = Self.clientIDs(in: data)
        let clientSecrets = Self.clientSecrets(in: data)
        guard let client = Self.preferredBinaryClient(
            clientIDs: clientIDs,
            clientSecrets: clientSecrets)
        else {
            return nil
        }

        return client
    }

    static func parseClient(fromInstalledArtifactText content: String) -> AntigravityOAuthClient? {
        let marker = "vs/platform/cloudCode/common/oauthClient.js"
        let searchStart = content.range(of: marker)?.lowerBound ?? content.startIndex
        let searchEnd = content.index(searchStart, offsetBy: 4000, limitedBy: content.endIndex) ?? content.endIndex
        let haystack = String(content[searchStart..<searchEnd])

        guard let clientID = Self.firstMatch(
            pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#,
            in: haystack),
            let clientSecret = Self.firstMatch(
                pattern: #"GOCSPX-[A-Za-z0-9_-]{28}"#,
                in: haystack)
        else {
            return nil
        }

        return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
    }

    private static func clientIDs(in data: Data) -> [String] {
        let suffix = Data(".apps.googleusercontent.com".utf8)
        var searchRange = data.startIndex..<data.endIndex
        var values: [String] = []

        while let range = data.range(of: suffix, options: [], in: searchRange) {
            var start = range.lowerBound
            while start > data.startIndex {
                let previous = data.index(before: start)
                guard Self.isOAuthClientIDPrefixByte(data[previous]) else { break }
                start = previous
            }

            let candidateData = Data(data[start..<range.upperBound])
            if let candidate = String(data: candidateData, encoding: .ascii),
               let clientID = Self.firstMatch(
                   pattern: #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#,
                   in: candidate)
            {
                values.append(clientID)
            }

            searchRange = range.upperBound..<data.endIndex
        }

        return self.unique(values)
    }

    private static func clientSecrets(in data: Data) -> [String] {
        let prefix = Data("GOCSPX-".utf8)
        let secretLength = 35
        var searchRange = data.startIndex..<data.endIndex
        var values: [String] = []

        while let range = data.range(of: prefix, options: [], in: searchRange) {
            let end = range.lowerBound + secretLength
            if end <= data.endIndex {
                let candidateData = Data(data[range.lowerBound..<end])
                if candidateData.dropFirst(prefix.count).allSatisfy(Self.isOAuthClientSecretByte),
                   let candidate = String(data: candidateData, encoding: .ascii)
                {
                    values.append(candidate)
                }
            }

            searchRange = range.upperBound..<data.endIndex
        }

        return self.unique(values)
    }

    private static func preferredBinaryClient(
        clientIDs: [String],
        clientSecrets: [String]) -> AntigravityOAuthClient?
    {
        guard !clientIDs.isEmpty,
              !clientSecrets.isEmpty
        else {
            return nil
        }

        if clientSecrets.count == 1, clientIDs.count > 1 {
            return AntigravityOAuthClient(clientID: clientIDs[clientIDs.count - 1], clientSecret: clientSecrets[0])
        }

        let clientSecret: String = if clientSecrets.count == clientIDs.count, clientSecrets.count > 1 {
            // Antigravity 2's language_server binary stores the secret table before the client id table.
            clientSecrets[clientSecrets.count - 1]
        } else {
            clientSecrets[0]
        }

        return AntigravityOAuthClient(clientID: clientIDs[0], clientSecret: clientSecret)
    }

    private static func isOAuthClientIDPrefixByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || byte == 45
            || byte == 95
    }

    private static func isOAuthClientSecretByte(_ byte: UInt8) -> Bool {
        self.isOAuthClientIDPrefixByte(byte)
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

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !seen.contains(value) else { return false }
            seen.insert(value)
            return true
        }
    }
}

public struct AntigravityOAuthCredentialsStore: @unchecked Sendable {
    public static let environmentCredentialsKey = "ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"

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

    public static func tokenAccountValue(for credentials: AntigravityOAuthCredentials) throws -> String {
        let data = try JSONEncoder.antigravityCredentials.encode(credentials)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public static func credentials(fromTokenAccountValue value: String) -> AntigravityOAuthCredentials? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
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
