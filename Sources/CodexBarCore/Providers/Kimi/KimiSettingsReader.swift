import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum KimiSettingsReader {
    public static let apiKeyEnvironmentKeys = ["KIMI_CODE_API_KEY"]
    public static let codeAPIBaseURLEnvironmentKey = "KIMI_CODE_BASE_URL"
    public static let codeHomeEnvironmentKey = "KIMI_CODE_HOME"
    public static let codeOAuthHostEnvironmentKeys = ["KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"]
    public static let defaultCodeAPIBaseURL = URL(string: "https://api.kimi.com")!
    public static let defaultCodeOAuthHost = URL(string: "https://auth.kimi.com")!
    private static let codeOAuthClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private static let codePlatform = "kimi_code_cli"

    public static func authToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["KIMI_AUTH_TOKEN"] ?? environment["kimi_auth_token"]
        return self.cleaned(raw)
    }

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func codeAPIBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL
    {
        guard let raw = self.cleaned(environment[self.codeAPIBaseURLEnvironmentKey]) else {
            return self.defaultCodeAPIBaseURL
        }

        guard URL(string: raw)?.scheme != nil,
              let url = ProviderEndpointOverrideValidator().validatedURL(raw)
        else {
            throw KimiAPIError.invalidRequest("Kimi Code API base URL must use HTTPS without user info")
        }
        return url
    }

    public static func kimiCodeAccessToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) -> String?
    {
        guard !self.hasCodeEndpointOverride(environment: environment) else { return nil }
        guard let url = self.kimiCodeCredentialsURL(environment: environment) else { return nil }
        return self.kimiCodeAccessToken(credentialsURL: url, now: now)
    }

    public static func kimiCodeAccessTokenRefreshing(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async -> String?
    {
        // The upstream CLI scopes OAuth credentials to the default API/OAuth pair.
        // Never forward that shared bearer or refresh token to an arbitrary override host.
        guard !self.hasCodeEndpointOverride(environment: environment) else { return nil }
        guard let url = self.kimiCodeCredentialsURL(environment: environment),
              let credential = self.kimiCodeCredential(credentialsURL: url)
        else {
            return nil
        }

        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty, self.isKimiCodeCredentialFresh(credential, now: now) {
            return token
        }

        guard let refreshed = await self.refreshKimiCodeCredential(
            credential,
            credentialsURL: url,
            environment: environment,
            now: now,
            transport: transport)
        else {
            return nil
        }
        return refreshed.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func kimiCodeCredentialsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.kimiCodeHomeURL(environment: environment)
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
    }

    private static func hasCodeEndpointOverride(environment: [String: String]) -> Bool {
        if self.cleaned(environment[self.codeAPIBaseURLEnvironmentKey]) != nil { return true }
        return self.codeOAuthHostEnvironmentKeys.contains { self.cleaned(environment[$0]) != nil }
    }

    private static func kimiCodeAccessToken(credentialsURL: URL, now: Date) -> String? {
        guard let credential = self.kimiCodeCredential(credentialsURL: credentialsURL) else { return nil }
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, self.isKimiCodeCredentialFresh(credential, now: now) else { return nil }
        return token
    }

    private static func kimiCodeCredential(credentialsURL: URL) -> KimiCodeOAuthCredential? {
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? JSONDecoder().decode(KimiCodeOAuthCredential.self, from: data)
    }

    private static func isKimiCodeCredentialFresh(_ credential: KimiCodeOAuthCredential, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(60).timeIntervalSince1970
    }

    private static func refreshKimiCodeCredential(
        _ credential: KimiCodeOAuthCredential,
        credentialsURL: URL,
        environment: [String: String],
        now: Date,
        transport: any ProviderHTTPTransport) async -> KimiCodeOAuthCredential?
    {
        let refreshToken = credential.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshToken.isEmpty else { return nil }
        guard let oauthHost = self.codeOAuthHost(environment: environment) else { return nil }
        let endpoint = oauthHost.appendingPathComponent("api").appendingPathComponent("oauth")
            .appendingPathComponent("token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in self.kimiCodeIdentityHeaders(environment: environment) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: self.codeOAuthClientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        guard let response = try? await transport.response(for: request), response.statusCode == 200,
              let refreshed = try? JSONDecoder().decode(KimiCodeOAuthRefreshResponse.self, from: response.data),
              let credential = refreshed.credential(now: now)
        else {
            return nil
        }
        try? self.saveKimiCodeCredential(credential, credentialsURL: credentialsURL)
        return credential
    }

    private static func codeOAuthHost(environment: [String: String]) -> URL? {
        for key in self.codeOAuthHostEnvironmentKeys {
            if let raw = self.cleaned(environment[key]) {
                return ProviderEndpointOverrideValidator().validatedURL(raw)
            }
        }
        return self.defaultCodeOAuthHost
    }

    static func kimiCodeIdentityHeaders(environment: [String: String]) -> [String: String] {
        let version = self.asciiHeaderValue(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        return [
            "User-Agent": "CodexBar/\(version)",
            "X-Msh-Platform": self.codePlatform,
            "X-Msh-Version": version,
            "X-Msh-Device-Name": self.asciiHeaderValue(ProcessInfo.processInfo.hostName),
            "X-Msh-Device-Model": self.asciiHeaderValue(
                "\(self.operatingSystemName) \(osVersionString) \(self.architectureName)"),
            "X-Msh-Os-Version": self.asciiHeaderValue(osVersionString),
            "X-Msh-Device-Id": self.kimiCodeDeviceID(environment: environment),
        ]
    }

    private static func kimiCodeDeviceID(environment: [String: String]) -> String {
        let home = self.kimiCodeHomeURL(environment: environment)
        let url = home.appendingPathComponent("device_id", isDirectory: false)
        if let existing = self.cleaned(try? String(contentsOf: url, encoding: .utf8)) {
            return existing
        }

        let deviceID = UUID().uuidString.lowercased()
        do {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try deviceID.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Match the Kimi client: persistence is best-effort; this request can still use the in-memory ID.
        }
        return deviceID
    }

    private static func asciiHeaderValue(_ raw: String, fallback: String = "unknown") -> String {
        var ascii = ""
        for scalar in raw.unicodeScalars where (0x20...0x7E).contains(scalar.value) {
            ascii.unicodeScalars.append(scalar)
        }
        let value = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private static var operatingSystemName: String {
        #if os(macOS)
        "macOS"
        #elseif os(Linux)
        "Linux"
        #else
        "unknown"
        #endif
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func saveKimiCodeCredential(
        _ credential: KimiCodeOAuthCredential,
        credentialsURL: URL) throws
    {
        var payload = self.existingKimiCodeCredentialPayload(credentialsURL: credentialsURL)
        payload["access_token"] = credential.accessToken
        payload["refresh_token"] = credential.refreshToken
        if let expiresAt = credential.expiresAt {
            payload["expires_at"] = expiresAt
        } else {
            payload.removeValue(forKey: "expires_at")
        }
        if let expiresIn = credential.expiresIn {
            payload["expires_in"] = expiresIn
        } else {
            payload.removeValue(forKey: "expires_in")
        }
        payload["scope"] = credential.scope
        payload["token_type"] = credential.tokenType

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: credentialsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: credentialsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)
    }

    private static func existingKimiCodeCredentialPayload(credentialsURL: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: credentialsURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return payload
    }

    private static func kimiCodeHomeURL(environment: [String: String]) -> URL {
        if let override = self.cleaned(environment[self.codeHomeEnvironmentKey]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct KimiCodeOAuthCredential: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval?
    let expiresIn: TimeInterval?
    let scope: String
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    init(
        accessToken: String,
        refreshToken: String,
        expiresAt: TimeInterval?,
        expiresIn: TimeInterval?,
        scope: String,
        tokenType: String)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
        self.scope = scope
        self.tokenType = tokenType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = (try? container.decode(String.self, forKey: .accessToken)) ?? ""
        self.refreshToken = (try? container.decode(String.self, forKey: .refreshToken)) ?? ""
        self.expiresAt = Self.timeIntervalValue(in: container, forKey: .expiresAt)
        self.expiresIn = Self.timeIntervalValue(in: container, forKey: .expiresIn)
        self.scope = (try? container.decode(String.self, forKey: .scope)) ?? ""
        self.tokenType = (try? container.decode(String.self, forKey: .tokenType)) ?? "Bearer"
    }

    private static func timeIntervalValue(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> TimeInterval?
    {
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return TimeInterval(value)
        }
        if let value = try? container.decode(String.self, forKey: key),
           let number = TimeInterval(value)
        {
            return number
        }
        return nil
    }
}

private struct KimiCodeOAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval?
    let scope: String
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = (try? container.decode(String.self, forKey: .accessToken)) ?? ""
        self.refreshToken = (try? container.decode(String.self, forKey: .refreshToken)) ?? ""
        self.expiresIn = Self.timeIntervalValue(in: container, forKey: .expiresIn)
        self.scope = (try? container.decode(String.self, forKey: .scope)) ?? ""
        self.tokenType = (try? container.decode(String.self, forKey: .tokenType)) ?? "Bearer"
    }

    func credential(now: Date) -> KimiCodeOAuthCredential? {
        let accessToken = self.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = self.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty, !refreshToken.isEmpty,
              let expiresIn, expiresIn > 0
        else {
            return nil
        }
        return KimiCodeOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.timeIntervalSince1970 + expiresIn,
            expiresIn: expiresIn,
            scope: self.scope,
            tokenType: self.tokenType.isEmpty ? "Bearer" : self.tokenType)
    }

    private static func timeIntervalValue(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> TimeInterval?
    {
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return TimeInterval(value)
        }
        if let value = try? container.decode(String.self, forKey: key),
           let number = TimeInterval(value)
        {
            return number
        }
        return nil
    }
}
