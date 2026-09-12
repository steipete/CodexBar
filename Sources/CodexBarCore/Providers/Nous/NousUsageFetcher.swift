import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Parsed `GET /api/oauth/account` response from Nous Portal.
public struct NousAccountSummary: Sendable, Equatable {
    public let email: String?
    public let organizationName: String?
    public let plan: String?
    public let monthlyCredits: Double
    public let creditsRemaining: Double
    public let rolloverCredits: Double
    public let currentPeriodEnd: Date?
    public let purchasedCreditsRemaining: Double
    public let totalUsableCredits: Double?
    public let hasActiveSubscription: Bool
    public let updatedAt: Date

    public init(
        email: String?,
        organizationName: String?,
        plan: String?,
        monthlyCredits: Double,
        creditsRemaining: Double,
        rolloverCredits: Double,
        currentPeriodEnd: Date?,
        purchasedCreditsRemaining: Double,
        totalUsableCredits: Double?,
        hasActiveSubscription: Bool,
        updatedAt: Date)
    {
        self.email = email
        self.organizationName = organizationName
        self.plan = plan
        self.monthlyCredits = monthlyCredits
        self.creditsRemaining = creditsRemaining
        self.rolloverCredits = rolloverCredits
        self.currentPeriodEnd = currentPeriodEnd
        self.purchasedCreditsRemaining = purchasedCreditsRemaining
        self.totalUsableCredits = totalUsableCredits
        self.hasActiveSubscription = hasActiveSubscription
        self.updatedAt = updatedAt
    }

    /// Plan row text. The header column is narrow, so keep it to the plan name; the top-up balance is shown in
    /// the Credits section and the credits snapshot instead.
    public var planRowText: String {
        self.plan ?? (self.hasActiveSubscription ? "Subscription" : "Free")
    }

    /// Monthly subscription credits consumed this cycle, as a percentage of the monthly grant.
    public var monthlyUsedPercent: Double? {
        guard self.monthlyCredits > 0 else { return nil }
        let used = max(0, self.monthlyCredits - max(0, self.creditsRemaining))
        return min(100, used / self.monthlyCredits * 100)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = self.monthlyUsedPercent.map { percent in
            RateWindow(
                usedPercent: percent,
                windowMinutes: nil,
                resetsAt: self.currentPeriodEnd,
                resetDescription: nil)
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .nous,
            accountEmail: self.email,
            accountOrganization: self.organizationName,
            loginMethod: self.planRowText)
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            details: self.detailSections(),
            subscriptionRenewsAt: self.currentPeriodEnd,
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: .exact)
    }

    public func toCreditsSnapshot() -> CreditsSnapshot {
        CreditsSnapshot(remaining: self.purchasedCreditsRemaining, events: [], updatedAt: self.updatedAt)
    }

    private func detailSections() -> [ProviderDetailSection] {
        var sections: [ProviderDetailSection] = []
        var subscriptionRows: [ProviderDetailSection.Row] = []
        if self.monthlyCredits > 0 {
            let remaining = UsageFormatter.usdString(max(0, self.creditsRemaining))
            let monthly = UsageFormatter.usdString(self.monthlyCredits)
            if let row = try? ProviderDetailSection.Row(label: "Subscription credits", value: "\(remaining) of \(monthly) left") {
                subscriptionRows.append(row)
            }
        }
        if self.rolloverCredits > 0,
           let row = try? ProviderDetailSection.Row(
               label: "Rollover credits",
               value: UsageFormatter.usdString(self.rolloverCredits))
        {
            subscriptionRows.append(row)
        }
        if let currentPeriodEnd,
           let row = try? ProviderDetailSection.Row(
               label: "Renews",
               value: Self.renewalFormatter.string(from: currentPeriodEnd))
        {
            subscriptionRows.append(row)
        }
        if !subscriptionRows.isEmpty, let section = try? ProviderDetailSection(title: "Subscription", rows: subscriptionRows) {
            sections.append(section)
        }

        var creditRows: [ProviderDetailSection.Row] = []
        if let row = try? ProviderDetailSection.Row(
            label: "Top-up credits",
            value: UsageFormatter.usdString(self.purchasedCreditsRemaining))
        {
            creditRows.append(row)
        }
        if let totalUsableCredits,
           let row = try? ProviderDetailSection.Row(label: "Total usable", value: UsageFormatter.usdString(totalUsableCredits))
        {
            creditRows.append(row)
        }
        if let section = try? ProviderDetailSection(title: "Credits", rows: creditRows) {
            sections.append(section)
        }
        return sections
    }

    private static let renewalFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

public enum NousUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case authFileInvalid(String)
    case sessionExpired(String)
    case environmentTokenExpired
    case unauthorized
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Nous Portal login not found. Run `hermes` and sign in to Nous Portal, or set NOUS_PORTAL_ACCESS_TOKEN."
        case let .authFileInvalid(path):
            "Hermes auth file at \(path) has no Nous Portal access token. Run `hermes auth add nous` to sign in."
        case let .sessionExpired(path):
            "Nous Portal access token in \(path) has expired. Run `hermes` so Hermes Agent refreshes it."
        case .environmentTokenExpired:
            "NOUS_PORTAL_ACCESS_TOKEN has expired. Export a fresh token or unset it to use the Hermes Agent login."
        case .unauthorized:
            "Nous Portal rejected the access token. Run `hermes` to refresh your Hermes Agent login."
        case let .networkError(message):
            "Nous Portal network error: \(message)"
        case let .apiError(message):
            "Nous Portal API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Nous Portal response: \(message)"
        }
    }
}

public struct NousUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.nous, scope: "usage"))
    private static let timeoutSeconds: TimeInterval = 15
    public static let accountPath = "/api/oauth/account"

    public static func fetchAccount(
        credential: NousSettingsReader.Credential,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> NousAccountSummary
    {
        let url = self.accountURL(portalBaseURL: credential.portalBaseURL)
        Self.log.info("Nous Portal account request → \(url.host ?? "?") (source: \(credential.source.label))")
        if let rejected = credential.rejectedPortalHost {
            Self.log.warning("Ignored untrusted stored portal_base_url host \(rejected); using \(url.host ?? "?")")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw NousUsageError.networkError("Invalid response")
        } catch let error as URLError {
            throw NousUsageError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            return try self.parseAccount(data: response.data, now: now)
        case 401:
            throw NousUsageError.unauthorized
        default:
            Self.log.error("Nous Portal account endpoint returned HTTP \(response.statusCode)")
            throw NousUsageError.apiError(self.errorMessage(data: response.data) ?? "HTTP \(response.statusCode)")
        }
    }

    public static func accountURL(portalBaseURL: URL) -> URL {
        URL(string: portalBaseURL.absoluteString + self.accountPath) ?? portalBaseURL
    }

    static func _parseAccountForTesting(_ data: Data, now: Date = Date()) throws -> NousAccountSummary {
        try self.parseAccount(data: data, now: now)
    }

    private static func parseAccount(data: Data, now: Date) throws -> NousAccountSummary {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NousUsageError.parseFailed("Expected a JSON object")
            }
            root = object
        } catch let error as NousUsageError {
            throw error
        } catch {
            throw NousUsageError.parseFailed(error.localizedDescription)
        }

        if let message = root["error"] as? String, !message.isEmpty {
            throw NousUsageError.apiError(message)
        }

        let user = root["user"] as? [String: Any] ?? [:]
        let organisation = root["organisation"] as? [String: Any] ?? [:]
        let subscription = root["subscription"] as? [String: Any]
        let access = root["paid_service_access"] as? [String: Any] ?? [:]

        guard subscription != nil || root["purchased_credits_remaining"] != nil || !access.isEmpty else {
            throw NousUsageError.parseFailed("Response has no subscription or credit fields")
        }

        let purchased = self.number(root["purchased_credits_remaining"])
            ?? self.number(access["purchased_credits_remaining"])
            ?? 0
        return NousAccountSummary(
            email: NousSettingsReader.cleaned(user["email"] as? String),
            organizationName: NousSettingsReader.cleaned(organisation["name"] as? String),
            plan: NousSettingsReader.cleaned(subscription?["plan"] as? String),
            monthlyCredits: self.number(subscription?["monthly_credits"]) ?? 0,
            creditsRemaining: self.number(subscription?["credits_remaining"])
                ?? self.number(access["subscription_credits_remaining"])
                ?? 0,
            rolloverCredits: self.number(subscription?["rollover_credits"]) ?? 0,
            currentPeriodEnd: (subscription?["current_period_end"] as? String).flatMap(NousSettingsReader.parseISODate),
            purchasedCreditsRemaining: purchased,
            totalUsableCredits: self.number(access["total_usable_credits"]),
            hasActiveSubscription: (access["has_active_subscription"] as? Bool) ?? (subscription != nil),
            updatedAt: now)
    }

    private static func errorMessage(data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["message"] as? String) ?? (root["error"] as? String)
    }

    /// Nous emits money as JSON numbers in the account payload and as decimal strings on billing routes.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: double
        case let int as Int: Double(int)
        case let string as String: Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }
}
