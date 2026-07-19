import Foundation

public enum KimiSettingsReader {
    public static let apiKeyEnvironmentKeys = ["KIMI_CODE_API_KEY"]
    public static let codeAPIBaseURLEnvironmentKey = "KIMI_CODE_BASE_URL"
    public static let codeHomeEnvironmentKey = "KIMI_CODE_HOME"
    public static let codeOAuthHostEnvironmentKeys = ["KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"]
    public static let defaultCodeAPIBaseURL = URL(string: "https://api.kimi.com")!
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
        guard !self.hasCodeEndpointOverride(environment: environment),
              let credential = self.kimiCodeCredential(environment: environment)
        else {
            return nil
        }
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, self.isKimiCodeCredentialFresh(credential, now: now) else { return nil }
        return token
    }

    public static func hasKimiCodeCredential(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard !self.hasCodeEndpointOverride(environment: environment),
              let credential = self.kimiCodeCredential(environment: environment)
        else {
            return false
        }
        return self.cleaned(credential.accessToken) != nil || self.cleaned(credential.refreshToken) != nil
    }

    static func kimiCodeIdentityHeaders(environment: [String: String]) -> [String: String] {
        let deviceID = self.kimiCodeDeviceID(environment: environment)
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
            "X-Msh-Device-Id": deviceID,
        ]
    }

    private static func hasCodeEndpointOverride(environment: [String: String]) -> Bool {
        if self.cleaned(environment[self.codeAPIBaseURLEnvironmentKey]) != nil { return true }
        return self.codeOAuthHostEnvironmentKeys.contains { self.cleaned(environment[$0]) != nil }
    }

    private static func kimiCodeCredential(environment: [String: String]) -> KimiCodeOAuthCredential? {
        let url = self.kimiCodeHomeURL(environment: environment)
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KimiCodeOAuthCredential.self, from: data)
    }

    private static func isKimiCodeCredentialFresh(_ credential: KimiCodeOAuthCredential, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt, expiresAt.isFinite else { return false }
        return expiresAt > now.addingTimeInterval(60).timeIntervalSince1970
    }

    private static func kimiCodeDeviceID(environment: [String: String]) -> String {
        let home = self.kimiCodeHomeURL(environment: environment)
        let url = home
            .appendingPathComponent("device_id", isDirectory: false)
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
            // The official client treats persistence as best-effort; this request can use the in-memory ID.
        }
        return deviceID
    }

    private static func kimiCodeHomeURL(environment: [String: String]) -> URL {
        if let override = self.cleaned(environment[self.codeHomeEnvironmentKey]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
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

private struct KimiCodeOAuthCredential: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case access = "access_token"
        case refresh = "refresh_token"
        case expiry = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = (try? container.decode(String.self, forKey: .access)) ?? ""
        self.refreshToken = (try? container.decode(String.self, forKey: .refresh)) ?? ""
        self.expiresAt = Self.timeIntervalValue(in: container, forKey: .expiry)
    }

    private static func timeIntervalValue(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> TimeInterval?
    {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return TimeInterval(value) }
        if let value = try? container.decode(String.self, forKey: key) { return TimeInterval(value) }
        return nil
    }
}
