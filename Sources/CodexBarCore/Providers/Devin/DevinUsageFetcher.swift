import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DevinUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.devin))
    private static let baseURL = URL(string: "https://app.devin.ai")!
    private static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    public struct RequestAuth: Sendable, Equatable {
        public let bearerToken: String
        public let organization: String?
        public let internalOrganizationID: String?
        public let sourceLabel: String

        public init(
            bearerToken: String,
            organization: String?,
            internalOrganizationID: String?,
            sourceLabel: String)
        {
            self.bearerToken = bearerToken
            self.organization = organization
            self.internalOrganizationID = internalOrganizationID
            self.sourceLabel = sourceLabel
        }
    }

    public let browserDetection: BrowserDetection

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    /// Normalizes a configured enterprise host into an absolute `https://host` URL.
    /// Accepts bare hosts (`your-team.devinenterprise.com`), full URLs, and values with paths
    /// (only the scheme+host are kept). Returns nil when the value is empty or invalid.
    public static func customHost(_ raw: String?) -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        var host = value
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }
        // Keep only the authority component; drop any path/query.
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, host.contains(".") else { return nil }
        return URL(string: "https://\(host)")
    }

    /// The base URL to hit: the custom enterprise host when set, otherwise app.devin.ai.
    public static func resolveHost(_ raw: String?) -> URL {
        self.customHost(raw) ?? self.baseURL
    }

    public func fetch(
        bearerTokenOverride: String? = nil,
        organizationOverride: String? = nil,
        apiHost: String? = nil,
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> DevinUsageSnapshot
    {
        let auths = try self.resolveAuths(
            bearerTokenOverride: bearerTokenOverride,
            organizationOverride: organizationOverride,
            apiHost: apiHost,
            logger: logger)
        var lastError: Error?
        for auth in auths {
            do {
                return try await Self.fetchQuotaUsage(
                    auth: auth,
                    organizationOverride: organizationOverride,
                    apiHost: apiHost,
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
        apiHost: String? = nil,
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> DevinUsageSnapshot
    {
        let organization = self.normalizedOrganization(organizationOverride) ??
            self.normalizedOrganization(auth.organization)
        guard let organization else {
            throw DevinUsageError.missingOrganization
        }

        let host = self.resolveHost(apiHost)

        // Enterprise deployment host: use the personal-analytics ACU cycle endpoint.
        if let customHost = self.customHost(apiHost) {
            let data = try await self.fetch(
                path: "personal-analytics/usage-limit",
                host: customHost,
                auth: auth,
                timeout: timeout,
                transport: transport)
            logger?("[devin] Fetched personal-analytics usage-limit from \(customHost.host ?? "")")
            return try DevinUsageParser.parsePersonalAnalytics(data, organization: organization, now: now)
        }

        var lastError: Error?
        for path in self.candidatePaths(
            organization: organization,
            internalOrganizationID: auth.internalOrganizationID)
        {
            let data: Data
            do {
                data = try await self.fetch(
                    path: path,
                    host: host,
                    auth: auth,
                    timeout: timeout,
                    transport: transport)
            } catch {
                lastError = error
                logger?("[devin] /api/\(path) failed: \(error.localizedDescription)")
                switch error {
                case DevinUsageError.invalidCredentials, DevinUsageError.missingOrganization: throw error
                default: continue
                }
            }
            logger?("[devin] Fetched quota usage from /api/\(path)")
            return try DevinUsageParser.parse(data, organization: organization, now: now)
        }

        throw lastError ?? DevinUsageError.apiError("No Devin quota endpoint succeeded.")
    }

    public static func manualAuth(from raw: String?, organization: String? = nil) -> RequestAuth? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        if token.lowercased().hasPrefix("authorization:") {
            token = String(token.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
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
        apiHost: String? = nil,
        logger: ((String) -> Void)?) throws -> [RequestAuth]
    {
        if let manual = Self.manualAuth(from: bearerTokenOverride, organization: organizationOverride) {
            logger?("[devin] Using manual Bearer token")
            return [manual]
        }

        #if os(macOS)
        let normalizedOrganizationOverride = Self.normalizedOrganization(organizationOverride)
        let storageOrigin = Self.customHost(apiHost)?.absoluteString
        let sessions = try DevinSessionImporter.importSessions(
            browserDetection: self.browserDetection,
            organizationOverride: normalizedOrganizationOverride,
            storageOrigin: storageOrigin,
            logger: logger)
        guard !sessions.isEmpty else {
            throw DevinUsageError.noSession
        }
        logger?("[devin] Found \(sessions.count) browser session(s)")
        return sessions.map { session in
            RequestAuth(
                bearerToken: session.accessToken,
                organization: normalizedOrganizationOverride ?? Self.normalizedOrganization(session.organization),
                internalOrganizationID: session.internalOrganizationID,
                sourceLabel: session.sourceLabel)
        }
        #else
        throw DevinUsageError.noSession
        #endif
    }

    static func shouldTryNextSession(after error: Error) -> Bool {
        switch error {
        case DevinUsageError.invalidCredentials, DevinUsageError.apiError, DevinUsageError.missingOrganization:
            true
        default:
            false
        }
    }

    private static func fetch(
        path: String,
        host: URL,
        auth: RequestAuth,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        let url = host.appending(path: "api/\(path)")
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
                let payload = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
                throw payload?["detail"] as? String == "No organizations found for auth1 user"
                    ? DevinUsageError.missingOrganization : DevinUsageError.invalidCredentials
            }
            Self.log.error("Devin API returned \(response.statusCode): \(body)")
            throw DevinUsageError.apiError("HTTP \(response.statusCode)")
        }
        return response.data
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
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public static func normalizedOrganization(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value),
           let host = url.host?.lowercased(),
           host == "devin.ai" || host.hasSuffix(".devin.ai")
        {
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
        if self.isInternalOrganizationID(value) {
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

    static func isInternalOrganizationID(_ value: String) -> Bool {
        value.hasPrefix("org-") || value.hasPrefix("org_")
    }
}
