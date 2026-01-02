import Foundation
import SweetCookieKit

#if os(macOS)

private let augmentCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.augment]?.browserCookieOrder ?? Browser.defaultImportOrder

// MARK: - Augment Cookie Importer

/// Imports Augment session cookies from browser cookies.
public enum AugmentCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    // Auth0 session cookies used by Augment
    private static let sessionCookieNames: Set<String> = [
        "_session",           // Legacy session cookie
        "auth0",              // Auth0 session
        "auth0.is.authenticated",  // Auth0 authentication flag
        "a0.spajs.txs",       // Auth0 SPA transaction state
    ]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    /// Attempts to import Augment cookies using the standard browser import order.
    public static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let log: (String) -> Void = { msg in logger?("[augment-cookie] \(msg)") }

        let cookieDomains = ["augmentcode.com", "login.augmentcode.com", ".augmentcode.com"]
        for browserSource in augmentCookieImportOrder {
            do {
                let query = BrowserCookieQuery(domains: cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)

                    // Log all cookies found for debugging
                    log("Found \(httpCookies.count) cookies in \(source.label): \(httpCookies.map { $0.name }.joined(separator: ", "))")

                    // Check if we have any session cookies
                    if httpCookies.contains(where: { Self.sessionCookieNames.contains($0.name) }) {
                        log("✓ Found Augment session cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    } else if !httpCookies.isEmpty {
                        // If we have ANY cookies for augmentcode.com, try using them
                        // This is more permissive and will help us discover what cookies are actually needed
                        log("⚠️ No known session cookies, but found \(httpCookies.count) cookies - attempting to use them")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    } else {
                        log("✗ \(source.label) has no cookies for augmentcode.com")
                    }
                }
            } catch {
                log("✗ \(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw AugmentStatusProbeError.noSessionCookie
    }

    /// Check if Augment session cookies are available
    public static func hasSession(logger: ((String) -> Void)? = nil) -> Bool {
        do {
            let session = try self.importSession(logger: logger)
            return !session.cookies.isEmpty
        } catch {
            return false
        }
    }
}

// MARK: - Augment API Models

public struct AugmentCreditsResponse: Codable, Sendable {
    public let usageUnitsAvailable: Int?
    public let usageUnitsPending: Int?
    public let usageUnitsRemaining: Int?
    public let usageUnitsConsumedThisBillingCycle: Int?
    public let usageBalanceStatus: String?

    enum CodingKeys: String, CodingKey {
        case usageUnitsAvailable
        case usageUnitsPending
        case usageUnitsRemaining
        case usageUnitsConsumedThisBillingCycle
        case usageBalanceStatus
    }
}

public struct AugmentSubscriptionResponse: Codable, Sendable {
    public let portalUrl: String?
    public let planName: String?
    public let status: String?
    public let monthlyCredits: Int?

    enum CodingKeys: String, CodingKey {
        case portalUrl
        case planName
        case status
        case monthlyCredits = "monthly_credits"
    }
}

public struct AugmentOrbCustomerResponse: Codable, Sendable {
    public let customer: AugmentOrbCustomer?
}

public struct AugmentOrbCustomer: Codable, Sendable {
    public let id: String?
    public let ledgerPricingUnits: [AugmentOrbPricingUnit]?

    enum CodingKeys: String, CodingKey {
        case id
        case ledgerPricingUnits = "ledger_pricing_units"
    }
}

public struct AugmentOrbPricingUnit: Codable, Sendable {
    public let id: String?
    public let name: String?
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName = "display_name"
    }
}

public struct AugmentOrbLedgerResponse: Codable, Sendable {
    public let creditsBalance: String?
    public let creditBlocks: [AugmentOrbCreditBlock]?

    enum CodingKeys: String, CodingKey {
        case creditsBalance = "credits_balance"
        case creditBlocks = "credit_blocks"
    }
}

public struct AugmentOrbCreditBlock: Codable, Sendable {
    public let balance: String?
    public let expiryDate: String?

    enum CodingKeys: String, CodingKey {
        case balance
        case expiryDate = "expiry_date"
    }
}

// MARK: - Augment Status Snapshot

public struct AugmentStatusSnapshot: Sendable {
    /// Current credit balance
    public let creditsBalance: Int
    /// Credits consumed this billing cycle
    public let creditsConsumed: Int?
    /// Monthly credit limit for the plan
    public let monthlyLimit: Int?
    /// Plan name (e.g., "Indie", "Standard", "Max")
    public let planName: String?
    /// Account status
    public let accountStatus: String?
    /// Credit blocks with expiry dates
    public let creditBlocks: [AugmentOrbCreditBlock]
    /// Raw JSON for debugging
    public let rawJSON: String?

    public init(
        creditsBalance: Int,
        creditsConsumed: Int? = nil,
        monthlyLimit: Int? = nil,
        planName: String?,
        accountStatus: String?,
        creditBlocks: [AugmentOrbCreditBlock],
        rawJSON: String?)
    {
        self.creditsBalance = creditsBalance
        self.creditsConsumed = creditsConsumed
        self.monthlyLimit = monthlyLimit
        self.planName = planName
        self.accountStatus = accountStatus
        self.creditBlocks = creditBlocks
        self.rawJSON = rawJSON
    }
}

// MARK: - Augment Status Probe Error

public enum AugmentStatusProbeError: Error, LocalizedError {
    case noSessionCookie
    case networkError(String)
    case parseFailed(String)
    case noPortalUrl
    case noCustomerId
    case noPricingUnit

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No Augment session cookie found. Please log in to app.augmentcode.com in your browser."
        case let .networkError(message):
            "Network error: \(message)"
        case let .parseFailed(message):
            "Failed to parse response: \(message)"
        case .noPortalUrl:
            "No portal URL found in subscription response"
        case .noCustomerId:
            "No customer ID found in Orb response"
        case .noPricingUnit:
            "No pricing unit found for credits"
        }
    }
}

// MARK: - Augment Status Probe

public struct AugmentStatusProbe: Sendable {
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(baseURL: URL = URL(string: "https://app.augmentcode.com")!, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    // MARK: - Debug Methods

    /// Fetch raw probe output for debugging purposes
    public func debugRawProbe(cookieHeaderOverride: String? = nil) async -> String {
        var debugLines: [String] = []
        let timestamp = ISO8601DateFormatter().string(from: Date())

        debugLines.append("=== Augment Debug Probe @ \(timestamp) ===")
        debugLines.append("")

        do {
            let snapshot = try await self.fetch(cookieHeaderOverride: cookieHeaderOverride) { msg in
                debugLines.append("[cookie-import] \(msg)")
            }

            debugLines.append("")
            debugLines.append("--- Probe Success ---")
            debugLines.append("Credits Balance: \(snapshot.creditsBalance)")
            if let consumed = snapshot.creditsConsumed {
                debugLines.append("Credits Consumed: \(consumed)")
            }
            if let monthlyLimit = snapshot.monthlyLimit {
                debugLines.append("Monthly Limit: \(monthlyLimit)")
            }
            if let planName = snapshot.planName {
                debugLines.append("Plan Name: \(planName)")
            }
            if let status = snapshot.accountStatus {
                debugLines.append("Account Status: \(status)")
            }
            debugLines.append("")

            if let rawJSON = snapshot.rawJSON {
                debugLines.append("--- Raw API Response ---")
                debugLines.append(rawJSON)
            }

            let result = debugLines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(result) }
            return result
        } catch {
            debugLines.append("")
            debugLines.append("--- Probe Failed ---")
            debugLines.append("Error: \(error.localizedDescription)")
            debugLines.append("")

            if let augmentError = error as? AugmentStatusProbeError {
                debugLines.append("Error Type: \(augmentError)")
            }

            let result = debugLines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(result) }
            return result
        }
    }

    // MARK: - Dump storage (in-memory ring buffer)

    @MainActor private static var recentDumps: [String] = []

    @MainActor private static func recordDump(_ text: String) {
        if self.recentDumps.count >= 5 { self.recentDumps.removeFirst() }
        self.recentDumps.append(text)
    }

    /// Retrieve the latest debug dumps from the ring buffer
    public static func latestDumps() async -> String {
        await MainActor.run {
            let result = Self.recentDumps.joined(separator: "\n\n---\n\n")
            return result.isEmpty ? "No Augment probe dumps captured yet." : result
        }
    }

    /// Fetch Augment usage with manual cookie header (for debugging).
    public func fetchWithManualCookies(_ cookieHeader: String) async throws -> AugmentStatusSnapshot {
        try await self.fetchWithCookieHeader(cookieHeader)
    }

    /// Fetch Augment usage using browser cookies with fallback to stored session.
    public func fetch(cookieHeaderOverride: String? = nil, logger: ((String) -> Void)? = nil)
        async throws -> AugmentStatusSnapshot
    {
        let cookieHeader: String
        if let override = cookieHeaderOverride {
            cookieHeader = override
        } else {
            let session = try AugmentCookieImporter.importSession(logger: logger)
            cookieHeader = session.cookieHeader
        }

        return try await self.fetchWithCookieHeader(cookieHeader)
    }

    private func fetchWithCookieHeader(_ cookieHeader: String) async throws -> AugmentStatusSnapshot {
        // Fetch both credits and subscription info in parallel
        async let creditsResult = self.fetchCredits(cookieHeader: cookieHeader)
        async let subscriptionResult = self.fetchSubscription(cookieHeader: cookieHeader)

        let ((credits, creditsJSON), (subscription, subscriptionJSON)) = try await (creditsResult, subscriptionResult)

        let creditsRemaining = credits.usageUnitsRemaining ?? 0
        let creditsConsumed = credits.usageUnitsConsumedThisBillingCycle
        let monthlyLimit = subscription.monthlyCredits

        // Combine both JSON responses for debugging
        let combinedJSON = """
            === Credits Response ===
            \(creditsJSON)

            === Subscription Response ===
            \(subscriptionJSON)
            """

        return AugmentStatusSnapshot(
            creditsBalance: creditsRemaining,
            creditsConsumed: creditsConsumed,
            monthlyLimit: monthlyLimit,
            planName: subscription.planName,
            accountStatus: subscription.status,
            creditBlocks: [],
            rawJSON: combinedJSON)
    }

    private func fetchCredits(cookieHeader: String) async throws -> (AugmentCreditsResponse, String) {
        let url = self.baseURL.appendingPathComponent("/api/credits")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AugmentStatusProbeError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
            throw AugmentStatusProbeError.networkError("HTTP \(httpResponse.statusCode): \(rawJSON.prefix(200))")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"

        do {
            let decoder = JSONDecoder()
            let credits = try decoder.decode(AugmentCreditsResponse.self, from: data)
            return (credits, rawJSON)
        } catch {
            throw AugmentStatusProbeError
                .parseFailed("JSON decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func fetchSubscription(cookieHeader: String) async throws -> (AugmentSubscriptionResponse, String) {
        let url = self.baseURL.appendingPathComponent("/api/subscription")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AugmentStatusProbeError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            throw AugmentStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"

        do {
            let decoder = JSONDecoder()
            let subscription = try decoder.decode(AugmentSubscriptionResponse.self, from: data)
            return (subscription, rawJSON)
        } catch {
            throw AugmentStatusProbeError
                .parseFailed("JSON decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func fetchOrbCustomer(token: String) async throws -> AugmentOrbCustomerResponse {
        let urlString = "https://portal.withorb.com/api/v1/customer_from_link?token=\(token)"
        guard let url = URL(string: urlString) else {
            throw AugmentStatusProbeError.parseFailed("Invalid Orb customer URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AugmentStatusProbeError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            throw AugmentStatusProbeError.networkError("Orb customer API: HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(AugmentOrbCustomerResponse.self, from: data)
        } catch {
            let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
            throw AugmentStatusProbeError
                .parseFailed("Orb customer decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func fetchOrbLedger(customerId: String, pricingUnitId: String, token: String)
        async throws -> (AugmentOrbLedgerResponse, String)
    {
        let urlString = "https://portal.withorb.com/api/v1/customers/\(customerId)/ledger_summary?pricing_unit_id=\(pricingUnitId)&token=\(token)"
        guard let url = URL(string: urlString) else {
            throw AugmentStatusProbeError.parseFailed("Invalid Orb ledger URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AugmentStatusProbeError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            throw AugmentStatusProbeError.networkError("Orb ledger API: HTTP \(httpResponse.statusCode)")
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"

        do {
            let decoder = JSONDecoder()
            let ledger = try decoder.decode(AugmentOrbLedgerResponse.self, from: data)
            return (ledger, rawJSON)
        } catch {
            throw AugmentStatusProbeError
                .parseFailed("Orb ledger decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    func parseLedger(
        _ ledger: AugmentOrbLedgerResponse,
        subscription: AugmentSubscriptionResponse,
        subscriptionJSON: String,
        ledgerJSON: String) -> AugmentStatusSnapshot
    {
        let creditsBalance = Int(Double(ledger.creditsBalance ?? "0") ?? 0)

        // Combine both JSON responses for debugging
        let combinedJSON = """
            === Subscription Response ===
            \(subscriptionJSON)

            === Ledger Response ===
            \(ledgerJSON)
            """

        return AugmentStatusSnapshot(
            creditsBalance: creditsBalance,
            creditsConsumed: nil,  // Ledger endpoint doesn't provide consumed credits
            monthlyLimit: subscription.monthlyCredits,
            planName: subscription.planName,
            accountStatus: subscription.status,
            creditBlocks: ledger.creditBlocks ?? [],
            rawJSON: combinedJSON)
    }
}

// MARK: - Usage Snapshot Conversion

extension AugmentStatusSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // Calculate usage percentage based on consumed credits and total available credits
        // Total available = remaining + consumed
        let usedPercent: Double
        let resetDescription: String

        if let consumed = self.creditsConsumed, consumed > 0 || self.creditsBalance > 0 {
            // Calculate total credits available this billing cycle
            let totalCredits = self.creditsBalance + consumed
            if totalCredits > 0 {
                usedPercent = (Double(consumed) / Double(totalCredits)) * 100.0
            } else {
                usedPercent = 0
            }
            resetDescription = "\(self.creditsBalance) credits remaining"
        } else {
            // Fallback: show 0% used if we don't have the data
            usedPercent = 0
            resetDescription = "\(self.creditsBalance) credits remaining"
        }

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: resetDescription)

        let identity = ProviderIdentitySnapshot(
            providerID: .augment,
            accountEmail: nil,
            accountOrganization: self.planName,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: nil,
            updatedAt: Date(),
            identity: identity)
    }
}

#endif


