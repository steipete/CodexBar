import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiOAuthCredentials: Sendable, Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: TimeInterval
    public let scope: String
    public let tokenType: String
    public let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    public var needsRefresh: Bool {
        self.accessToken.isEmpty || Date().timeIntervalSince1970 >= (self.expiresAt - 300)
    }
}

public enum KimiOAuthCredentialsError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Kimi Code CLI credentials not found. Run `kimi` and sign in first."
        case .invalidCredentials:
            "Kimi Code CLI credentials are invalid."
        case let .refreshFailed(message):
            "Failed to refresh Kimi Code CLI credentials: \(message)"
        }
    }
}

enum KimiOAuthCredentialsStore {
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    static func load(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) throws -> KimiOAuthCredentials
    {
        let url = KimiSettingsReader.credentialsFileURL(environment: env, homeDirectory: fileManager.homeDirectoryForCurrentUser)
        guard let data = try? Data(contentsOf: url) else {
            throw KimiOAuthCredentialsError.missingCredentials
        }
        guard let credentials = try? JSONDecoder().decode(KimiOAuthCredentials.self, from: data),
              !credentials.accessToken.isEmpty || !credentials.refreshToken.isEmpty
        else {
            throw KimiOAuthCredentialsError.invalidCredentials
        }
        return credentials
    }

    static func save(
        _ credentials: KimiOAuthCredentials,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) throws
    {
        let url = KimiSettingsReader.credentialsFileURL(environment: env, homeDirectory: fileManager.homeDirectoryForCurrentUser)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: url, options: .atomic)
        #if os(macOS)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    static func refresh(
        _ credentials: KimiOAuthCredentials,
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) async throws -> KimiOAuthCredentials
    {
        guard !credentials.refreshToken.isEmpty else {
            throw KimiOAuthCredentialsError.refreshFailed("missing refresh token")
        }

        let refreshURL = KimiSettingsReader.oauthHost(environment: env)
            .appending(path: "api/oauth/token")

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (header, value) in self.commonHeaders(env: env, fileManager: fileManager) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let body = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: credentials.refreshToken),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiOAuthCredentialsError.refreshFailed("invalid response")
        }
        guard http.statusCode == 200 else {
            let payload = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw KimiOAuthCredentialsError.refreshFailed(payload)
        }

        guard let refreshed = try? JSONDecoder().decode(KimiOAuthCredentials.self, from: data),
              !refreshed.accessToken.isEmpty
        else {
            throw KimiOAuthCredentialsError.refreshFailed("invalid payload")
        }

        try self.save(refreshed, env: env, fileManager: fileManager)
        return refreshed
    }

    private static func commonHeaders(
        env: [String: String],
        fileManager: FileManager) -> [String: String]
    {
        let processInfo = ProcessInfo.processInfo
        let model = self.asciiHeaderValue("\(processInfo.operatingSystemVersionString) \(processInfo.processorCount)cpu")
        let deviceName = self.asciiHeaderValue(Host.current().localizedName ?? "unknown")
        let osVersion = self.asciiHeaderValue(processInfo.operatingSystemVersionString)
        let deviceID = self.deviceID(env: env, fileManager: fileManager)

        return [
            "X-Msh-Platform": "codexbar",
            "X-Msh-Version": "1.0",
            "X-Msh-Device-Name": deviceName,
            "X-Msh-Device-Model": model,
            "X-Msh-Os-Version": osVersion,
            "X-Msh-Device-Id": deviceID,
        ]
    }

    private static func deviceID(
        env: [String: String],
        fileManager: FileManager) -> String
    {
        let url = KimiSettingsReader.deviceIDFileURL(environment: env, homeDirectory: fileManager.homeDirectoryForCurrentUser)
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let cleaned = KimiSettingsReader.cleaned(raw)
        {
            return cleaned
        }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? generated.write(to: url, atomically: true, encoding: .utf8)
        #if os(macOS)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
        return generated
    }

    private static func asciiHeaderValue(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = String(String.UnicodeScalarView(cleaned.unicodeScalars.filter { $0.isASCII }))
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}

private extension Array where Element == URLQueryItem {
    var percentEncodedQuery: String? {
        var components = URLComponents()
        components.queryItems = self
        return components.percentEncodedQuery
    }
}
