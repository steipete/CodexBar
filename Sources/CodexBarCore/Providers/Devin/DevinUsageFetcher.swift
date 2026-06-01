import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DevinUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.devin)
    private static let baseURL = URL(string: "https://app.devin.ai")!
    private static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    public struct RequestAuth: Sendable, Equatable {
        public struct RefreshSession: Sendable, Equatable {
            public let tokenEndpoint: URL
            public let clientID: String
            public let audience: String?
            public let scope: String?

            public init(tokenEndpoint: URL, clientID: String, audience: String?, scope: String?) {
                self.tokenEndpoint = tokenEndpoint
                self.clientID = clientID
                self.audience = audience
                self.scope = scope
            }
        }

        public let bearerToken: String
        public let refreshToken: String?
        public let refreshSession: RefreshSession?
        public let organization: String?
        public let internalOrganizationID: String?
        public let sourceLabel: String

        public init(
            bearerToken: String,
            refreshToken: String? = nil,
            refreshSession: RefreshSession? = nil,
            organization: String?,
            internalOrganizationID: String?,
            sourceLabel: String)
        {
            self.bearerToken = bearerToken
            self.refreshToken = refreshToken
            self.refreshSession = refreshSession
            self.organization = organization
            self.internalOrganizationID = internalOrganizationID
            self.sourceLabel = sourceLabel
        }
    }

    public let browserDetection: BrowserDetection

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    public func fetch(
        bearerTokenOverride: String? = nil,
        organizationOverride: String? = nil,
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> DevinUsageSnapshot
    {
        let auths = try self.resolveAuths(
            bearerTokenOverride: bearerTokenOverride,
            organizationOverride: organizationOverride,
            logger: logger)
        var lastError: Error?
        for auth in auths {
            do {
                return try await Self.fetchQuotaUsage(
                    auth: auth,
                    organizationOverride: organizationOverride,
                    timeout: timeout,
                    logger: logger,
                    now: now,
                    transport: transport)
            } catch {
                lastError = error
                logger?("[devin] Session from \(auth.sourceLabel) failed: \(error.localizedDescription)")
                if auth.sourceLabel == "manual" || !Self.shouldTryNextSession(after: error) {
                    throw error
                }
            }
        }
        throw lastError ?? DevinUsageError.noSession
    }

    public static func fetchQuotaUsage(
        auth: RequestAuth,
        organizationOverride: String? = nil,
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> DevinUsageSnapshot
    {
        let organization = self.normalizedOrganization(organizationOverride ?? auth.organization)
        guard let organization else {
            throw DevinUsageError.missingOrganization
        }

        var lastError: Error?
        var currentAuth = auth
        var didRefreshToken = false

        retryPaths: while true {
            for path in self.candidatePaths(
                organization: organization,
                internalOrganizationID: currentAuth.internalOrganizationID)
            {
                do {
                    let data = try await self.fetch(
                        path: path,
                        auth: currentAuth,
                        timeout: timeout,
                        transport: transport)
                    logger?("[devin] Fetched quota usage from /api/\(path)")
                    return try DevinUsageParser.parse(data, organization: organization, now: now)
                } catch {
                    lastError = error
                    logger?("[devin] /api/\(path) failed: \(error.localizedDescription)")
                    if case DevinUsageError.invalidCredentials = error {
                        guard !didRefreshToken,
                              let refreshedAuth = try await self.refreshedAuth(
                                  from: currentAuth,
                                  timeout: timeout,
                                  logger: logger,
                                  transport: transport)
                        else {
                            throw error
                        }
                        currentAuth = refreshedAuth
                        didRefreshToken = true
                        continue retryPaths
                    }
                }
            }
            break
        }

        throw lastError ?? DevinUsageError.apiError("No Devin quota endpoint succeeded.")
    }

    public static func manualAuth(from raw: String?, organization: String? = nil) -> RequestAuth? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        if token.lowercased().hasPrefix("authorization:") {
            token = token.dropHeaderName().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token.isEmpty else { return nil }
        return RequestAuth(
            bearerToken: token,
            organization: self.normalizedOrganization(organization),
            internalOrganizationID: self.internalOrganizationID(from: organization),
            sourceLabel: "manual")
    }

    private func resolveAuths(
        bearerTokenOverride: String?,
        organizationOverride: String?,
        logger: ((String) -> Void)?) throws -> [RequestAuth]
    {
        if let manual = Self.manualAuth(from: bearerTokenOverride, organization: organizationOverride) {
            logger?("[devin] Using manual Bearer token")
            return [manual]
        }

        #if os(macOS)
        let sessions = DevinSessionImporter.importSessions(
            browserDetection: self.browserDetection,
            organizationOverride: organizationOverride,
            logger: logger)
        guard !sessions.isEmpty else {
            throw DevinUsageError.noSession
        }
        logger?("[devin] Found \(sessions.count) browser session(s)")
        return sessions.map { session in
            RequestAuth(
                bearerToken: session.accessToken,
                refreshToken: session.refreshToken,
                refreshSession: session.auth0.map {
                    RequestAuth.RefreshSession(
                        tokenEndpoint: $0.tokenEndpoint,
                        clientID: $0.clientID,
                        audience: $0.audience,
                        scope: $0.scope)
                },
                organization: Self.normalizedOrganization(organizationOverride ?? session.organization),
                internalOrganizationID: session.internalOrganizationID,
                sourceLabel: session.sourceLabel)
        }
        #else
        throw DevinUsageError.noSession
        #endif
    }

    private static func shouldTryNextSession(after error: Error) -> Bool {
        switch error {
        case DevinUsageError.invalidCredentials, DevinUsageError.apiError:
            true
        default:
            false
        }
    }

    private static func fetch(
        path: String,
        auth: RequestAuth,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        let url = self.baseURL.appending(path: "api/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(auth.bearerToken)", forHTTPHeaderField: "Authorization")
        if let internalOrganizationID = auth.internalOrganizationID {
            request.setValue(internalOrganizationID, forHTTPHeaderField: "x-cog-org-id")
        }
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            let body = String(data: response.data.prefix(200), encoding: .utf8) ?? "<binary>"
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DevinUsageError.invalidCredentials
            }
            Self.log.error("Devin API returned \(response.statusCode): \(body)")
            throw DevinUsageError.apiError("HTTP \(response.statusCode)")
        }
        return response.data
    }

    private static func refreshedAuth(
        from auth: RequestAuth,
        timeout: TimeInterval,
        logger: ((String) -> Void)?,
        transport: any ProviderHTTPTransport) async throws -> RequestAuth?
    {
        guard let refreshToken = auth.refreshToken,
              let refreshSession = auth.refreshSession
        else {
            return nil
        }
        let accessToken = try await self.refreshAccessToken(
            refreshToken: refreshToken,
            session: refreshSession,
            timeout: timeout,
            transport: transport)
        logger?("[devin] Refreshed expired browser access token")
        return RequestAuth(
            bearerToken: accessToken,
            refreshToken: refreshToken,
            refreshSession: refreshSession,
            organization: auth.organization,
            internalOrganizationID: auth.internalOrganizationID,
            sourceLabel: auth.sourceLabel)
    }

    private static func refreshAccessToken(
        refreshToken: String,
        session: RequestAuth.RefreshSession,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> String
    {
        var request = URLRequest(url: session.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var items = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: session.clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        if let audience = session.audience, !audience.isEmpty {
            items.append(URLQueryItem(name: "audience", value: audience))
        }
        if let scope = session.scope, !scope.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        var components = URLComponents()
        components.queryItems = items
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            throw DevinUsageError.invalidCredentials
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DevinUsageError.parseFailed("Missing refreshed access token.")
        }
        return accessToken
    }

    private static func candidatePaths(organization: String, internalOrganizationID: String?) -> [String] {
        var paths: [String] = []
        let normalized = self.normalizedOrganization(organization) ?? organization
        if let internalOrganizationID {
            paths.append("\(internalOrganizationID)/billing/quota/usage")
        }
        paths.append("\(normalized)/billing/quota/usage")
        if normalized.hasPrefix("org/") {
            let slug = String(normalized.dropFirst(4))
            paths.append("\(slug)/billing/quota/usage")
        }
        if !normalized.hasPrefix("org/"), !normalized.hasPrefix("organizations/") {
            paths.append("org/\(normalized)/billing/quota/usage")
        }
        if let internalOrganizationID {
            paths.append("organizations/\(internalOrganizationID)/billing/quota/usage")
        }
        return paths.removingDuplicates()
    }

    public static func normalizedOrganization(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value), let host = url.host, host.contains("devin.ai") {
            let components = url.path.split(separator: "/").map(String.init)
            if components.count >= 2, components[0] == "org" {
                value = "org/\(components[1])"
            } else if components.count >= 2, components[0] == "organizations" {
                value = "organizations/\(components[1])"
            }
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasPrefix("org/") || value.hasPrefix("organizations/") {
            return value
        }
        if value.hasPrefix("org-") {
            return "organizations/\(value)"
        }
        return "org/\(value)"
    }

    private static func internalOrganizationID(from raw: String?) -> String? {
        guard let normalized = self.normalizedOrganization(raw),
              normalized.hasPrefix("organizations/")
        else {
            return nil
        }
        return String(normalized.dropFirst("organizations/".count))
    }
}

extension String {
    fileprivate func dropHeaderName() -> String {
        guard let index = self.firstIndex(of: ":") else { return self }
        return String(self[self.index(after: index)...])
    }
}

extension [String] {
    fileprivate func removingDuplicates() -> [String] {
        var seen = Set<String>()
        return self.filter { seen.insert($0).inserted }
    }
}
