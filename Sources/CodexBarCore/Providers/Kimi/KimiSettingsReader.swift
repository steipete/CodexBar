import Foundation

public enum KimiSettingsReader {
    public static let apiKeyEnvironmentKeys = ["KIMI_CODE_API_KEY"]
    public static let codeAPIBaseURLEnvironmentKey = "KIMI_CODE_BASE_URL"
    public static let codeHomeEnvironmentKey = "KIMI_CODE_HOME"
    public static let defaultCodeAPIBaseURL = URL(string: "https://api.kimi.com")!

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
        guard let url = self.kimiCodeCredentialsURL(environment: environment) else { return nil }
        return self.kimiCodeAccessToken(credentialsURL: url, now: now)
    }

    public static func kimiCodeCredentialsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        let home: URL = if let override = self.cleaned(environment[self.codeHomeEnvironmentKey]) {
            URL(fileURLWithPath: override, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kimi-code", isDirectory: true)
        }
        return home
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
    }

    private static func kimiCodeAccessToken(credentialsURL: URL, now: Date) -> String? {
        guard let data = try? Data(contentsOf: credentialsURL),
              let credential = try? JSONDecoder().decode(KimiCodeOAuthCredential.self, from: data)
        else {
            return nil
        }
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        if let expiresAt = credential.expiresAt,
           expiresAt <= now.addingTimeInterval(60).timeIntervalSince1970
        {
            return nil
        }
        return token
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
    let expiresAt: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = (try? container.decode(String.self, forKey: .accessToken)) ?? ""
        self.expiresAt = Self.timeIntervalValue(in: container, forKey: .expiresAt)
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
