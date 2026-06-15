import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotUsageFetcher: Sendable {
    public struct GitHubUserIdentity: Decodable, Equatable, Sendable {
        public let id: Int64
        public let login: String

        public init(id: Int64, login: String) {
            self.id = id
            self.login = login
        }
    }

    private let token: String
    private let enterpriseHost: String?
    private let transport: any ProviderHTTPTransport

    public init(
        token: String,
        enterpriseHost: String? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        self.token = token
        self.enterpriseHost = enterpriseHost
        self.transport = transport
    }

    public static func apiHost(enterpriseHost: String?) -> String {
        let host = CopilotDeviceFlow.normalizedHost(enterpriseHost)
        if host == CopilotDeviceFlow.defaultHost {
            return "api.github.com"
        }
        if host.hasPrefix("api.") {
            return host
        }
        return "api.\(host)"
    }

    public static func usageURL(enterpriseHost: String?) -> URL? {
        CopilotDeviceFlow.makeRequestURL(
            host: self.apiHost(enterpriseHost: enterpriseHost),
            path: "/copilot_internal/user")
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let url = Self.usageURL(enterpriseHost: self.enterpriseHost) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        // Use the GitHub OAuth token directly, not the Copilot token.
        request.setValue("token \(self.token)", forHTTPHeaderField: "Authorization")
        self.addCommonHeaders(to: &request)

        let response = try await self.transport.response(for: request)

        if response.statusCode == 401 || response.statusCode == 403 {
            throw URLError(.userAuthenticationRequired)
        }

        guard response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let usage = try JSONDecoder().decode(CopilotUsageResponse.self, from: response.data)
        let resetsAt = Self.parseQuotaResetDate(usage.quotaResetDate)
        let premium = Self.makeRateWindow(from: usage.quotaSnapshots.premiumInteractions, resetsAt: resetsAt)
        let chat = Self.makeRateWindow(from: usage.quotaSnapshots.chat, resetsAt: resetsAt)

        let primary: RateWindow?
        let secondary: RateWindow?
        if let premium {
            primary = premium
            secondary = chat
        } else if let chatWindow = chat {
            // Keep chat in the secondary slot so provider labels remain accurate
            // ("Premium" for primary, "Chat" for secondary) on chat-only plans.
            primary = nil
            secondary = chatWindow
        } else if usage.tokenBasedBilling {
            // Copilot Business token-based billing currently exposes zero-entitlement
            // placeholder quotas on this endpoint, so surface the plan without fake usage.
            primary = nil
            secondary = nil
        } else {
            throw URLError(.cannotDecodeRawData)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .copilot,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: usage.copilotPlan.capitalized)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    public static func fetchGitHubUsername(token: String) async throws -> String {
        try await self.fetchGitHubIdentity(token: token).login
    }

    public static func fetchGitHubIdentity(
        token: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
        async throws -> GitHubUserIdentity
    {
        guard let url = URL(string: "https://api.github.com/user") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        switch response.statusCode {
        case 200:
            return try JSONDecoder().decode(GitHubUserIdentity.self, from: response.data)
        case 401, 403:
            throw URLError(.userAuthenticationRequired)
        default:
            throw URLError(.badServerResponse)
        }
    }

    private func addCommonHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
    }

    static func makeRateWindow(
        from snapshot: CopilotUsageResponse.QuotaSnapshot?,
        resetsAt: Date? = nil) -> RateWindow?
    {
        guard let snapshot else { return nil }
        guard !snapshot.isPlaceholder else { return nil }
        guard snapshot.hasPercentRemaining else { return nil }
        let usedPercent = snapshot.usedPercent
        let overQuotaDescription = snapshot.overQuotaUsedPercent.map { used in
            String(format: "%.0f%% used", used)
        }
        let effectiveResetsAt = snapshot.unlimited ? nil : resetsAt

        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: effectiveResetsAt,
            resetDescription: overQuotaDescription)
    }

    static func parseQuotaResetDate(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalISO.date(from: raw) {
            return date
        }

        let internetISO = ISO8601DateFormatter()
        internetISO.formatOptions = [.withInternetDateTime]
        if let date = internetISO.date(from: raw) {
            return date
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
