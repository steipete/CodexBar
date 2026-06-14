import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ZedTokenBillingSnapshot: Sendable, Equatable {
    public let spentUSD: Double?
    public let includedUSD: Double?
    public let spendLimitUSD: Double?
    public let periodEnd: Date?

    public init(
        spentUSD: Double?,
        includedUSD: Double?,
        spendLimitUSD: Double?,
        periodEnd: Date?)
    {
        self.spentUSD = spentUSD
        self.includedUSD = includedUSD
        self.spendLimitUSD = spendLimitUSD
        self.periodEnd = periodEnd
    }
}

public enum ZedDashboardBillingError: LocalizedError, Sendable, Equatable {
    case noSessionCookie
    case invalidManualCookie
    case missingSessionCookie
    case unauthorized
    case networkError(String)
    case requestFailed(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            """
            No Zed dashboard session found. Sign in to dashboard.zed.dev in a browser, then enable Auto or paste \
            cookies manually.
            """
        case .invalidManualCookie:
            "The manual Zed dashboard cookie header is empty."
        case .missingSessionCookie:
            """
            Cookie header must include zed.session from a signed-in dashboard.zed.dev request to \
            cloud.zed.dev. Do not paste Set-Cookie __cf_bm lines alone.
            """
        case .unauthorized:
            "Zed dashboard session is invalid or expired. Sign in to dashboard.zed.dev again."
        case let .networkError(message):
            "Zed dashboard billing request failed: \(message)"
        case let .requestFailed(status):
            "Zed dashboard billing request failed with HTTP \(status)."
        case let .parseFailed(message):
            "Could not parse Zed dashboard billing response: \(message)"
        }
    }
}

public enum ZedDashboardBillingFetcher {
    public static let billingUsageURL =
        URL(string: "https://cloud.zed.dev/frontend/billing/usage")!
    private static let requestTimeoutSeconds: TimeInterval = 15
    private static let logger = CodexBarLog.logger(LogCategories.zed)

    public static func fetch(
        browserDetection: BrowserDetection,
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String?,
        timeout: TimeInterval = 15,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        logger: ((String) -> Void)? = nil) async throws -> ZedTokenBillingSnapshot?
    {
        switch cookieSource {
        case .off:
            return nil
        case .manual:
            guard let normalized = CookieHeaderNormalizer.normalize(manualCookieHeader ?? ""),
                  !normalized.isEmpty
            else {
                throw ZedDashboardBillingError.invalidManualCookie
            }
            if ZedCookieHeader.isCloudflareOnly(normalized) {
                throw ZedDashboardBillingError.missingSessionCookie
            }
            guard let billingHeader = ZedCookieHeader.filteredBillingHeader(from: normalized) else {
                throw ZedDashboardBillingError.missingSessionCookie
            }
            return try await self.fetch(
                cookieHeader: billingHeader,
                timeout: timeout,
                transport: transport,
                logger: logger)
        case .auto:
            #if os(macOS)
            let session = try ZedCookieImporter.importSession(
                browserDetection: browserDetection,
                logger: logger)
            guard let billingHeader = ZedCookieHeader.filteredBillingHeader(from: session.cookieHeader) else {
                throw ZedDashboardBillingError.missingSessionCookie
            }
            return try await self.fetch(
                cookieHeader: billingHeader,
                timeout: timeout,
                transport: transport,
                logger: logger)
            #else
            throw ZedDashboardBillingError.noSessionCookie
            #endif
        }
    }

    public static func parseResponse(_ data: Data) throws -> ZedTokenBillingSnapshot {
        let response: ZedDashboardBillingUsageResponse
        do {
            response = try JSONDecoder().decode(ZedDashboardBillingUsageResponse.self, from: data)
        } catch {
            throw ZedDashboardBillingError.parseFailed(error.localizedDescription)
        }

        guard let tokenSpend = response.currentUsage?.tokenSpend else {
            throw ZedDashboardBillingError.parseFailed("Missing current_usage.token_spend")
        }

        let includedUSD = Self.includedUSD(forPlan: response.plan)
        let limitUSD = tokenSpend.limitInCents.map { Double($0) / 100.0 }
        let spendLimitUSD = Self.spendLimitUSD(limitUSD: limitUSD, includedUSD: includedUSD)

        return ZedTokenBillingSnapshot(
            spentUSD: Double(tokenSpend.spendInCents) / 100.0,
            includedUSD: includedUSD,
            spendLimitUSD: spendLimitUSD,
            periodEnd: nil)
    }

    private static func fetch(
        cookieHeader: String,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport,
        logger: ((String) -> Void)?) async throws -> ZedTokenBillingSnapshot
    {
        guard !cookieHeader.isEmpty else {
            throw ZedDashboardBillingError.noSessionCookie
        }

        var request = URLRequest(url: Self.billingUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout > 0 ? timeout : Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://dashboard.zed.dev", forHTTPHeaderField: "Origin")
        request.setValue("https://dashboard.zed.dev/billing", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            Self.logger.debug("Zed dashboard billing transport failed: \(error.localizedDescription)")
            logger?("[zed-dashboard] Transport failed: \(error.localizedDescription)")
            throw ZedDashboardBillingError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            let snapshot = try Self.parseResponse(response.data)
            logger?("[zed-dashboard] Parsed token spend \(snapshot.spentUSD ?? 0)")
            return snapshot
        case 401, 403:
            throw ZedDashboardBillingError.unauthorized
        default:
            throw ZedDashboardBillingError.requestFailed(response.statusCode)
        }
    }

    static func includedUSD(forPlan rawPlan: String) -> Double? {
        switch rawPlan.lowercased() {
        case "zed_pro": 5
        case "zed_student": 10
        case "zed_pro_trial": 20
        default: nil
        }
    }

    static func spendLimitUSD(limitUSD: Double?, includedUSD: Double?) -> Double? {
        guard let limitUSD else { return nil }
        guard let includedUSD else { return limitUSD }
        return limitUSD > includedUSD ? limitUSD : nil
    }
}

private struct ZedDashboardBillingUsageResponse: Decodable {
    let plan: String
    let currentUsage: ZedDashboardCurrentUsage?

    enum CodingKeys: String, CodingKey {
        case plan
        case currentUsage = "current_usage"
    }
}

private struct ZedDashboardCurrentUsage: Decodable {
    let tokenSpend: ZedDashboardTokenSpend

    enum CodingKeys: String, CodingKey {
        case tokenSpend = "token_spend"
    }
}

private struct ZedDashboardTokenSpend: Decodable {
    let spendInCents: Int
    let limitInCents: Int?

    enum CodingKeys: String, CodingKey {
        case spendInCents = "spend_in_cents"
        case limitInCents = "limit_in_cents"
    }
}
