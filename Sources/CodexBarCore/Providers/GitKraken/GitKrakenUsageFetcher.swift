import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum GitKrakenSettingsReader {
    static let tokenKey = "GITKRAKEN_API_TOKEN"
    static let organizationKey = "GITKRAKEN_ORG_ID"

    static func accessToken(environment: [String: String]) -> String? {
        SettingsValue.cleaned(environment[self.tokenKey])
    }

    static func organizationID(environment: [String: String]) -> String? {
        SettingsValue.cleaned(environment[self.organizationKey])
    }

    static func isHeaderValue(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumLength &&
            value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
}

enum GitKrakenUsageFetcher {
    static let usageURL = URL(string: "https://api.gitkraken.dev/v1/ai-tasks/usage")!
    private static let transport: any ProviderHTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

    static func makeRequest(token: String, organizationID: String?) throws -> URLRequest {
        guard GitKrakenSettingsReader.isHeaderValue(token, maximumLength: 16384) else {
            throw GitKrakenUsageError.invalidToken
        }
        if let organizationID,
           !GitKrakenSettingsReader.isHeaderValue(organizationID, maximumLength: 256)
        {
            throw GitKrakenUsageError.invalidOrganization
        }
        var request = URLRequest(url: self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Identify this client honestly; do not impersonate GitLens or use its OAuth client ID.
        request.setValue("CodexBar", forHTTPHeaderField: "Client-Name")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        request.setValue(version ?? "0.0.0", forHTTPHeaderField: "Client-Version")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        if let organizationID {
            request.setValue(organizationID, forHTTPHeaderField: "gk-org-id")
        }
        return request
    }

    static func fetch(
        token: String,
        organizationID: String? = nil,
        transport: any ProviderHTTPTransport = Self.transport) async throws -> GitKrakenUsage
    {
        try Task.checkCancellation()
        let request = try self.makeRequest(token: token, organizationID: organizationID)
        let response = try await transport.response(for: request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            throw GitKrakenUsageError.httpError(response.statusCode)
        }
        return try GitKrakenUsage.parseAPI(response.data)
    }
}
