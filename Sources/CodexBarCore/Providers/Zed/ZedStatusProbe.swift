import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models

public struct ZedAuthenticatedUserResponse: Decodable, Equatable, Sendable {
    public let user: ZedAuthenticatedUser
    public let plan: ZedPlanInfo

    public init(user: ZedAuthenticatedUser, plan: ZedPlanInfo) {
        self.user = user
        self.plan = plan
    }
}

public struct ZedAuthenticatedUser: Decodable, Equatable, Sendable {
    public let id: Int
    public let githubLogin: String
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case githubLogin = "github_login"
        case name
    }
}

public struct ZedPlanInfo: Decodable, Equatable, Sendable {
    public let planV3: String
    public let subscriptionPeriod: ZedSubscriptionPeriod?
    public let usage: ZedCurrentUsage
    public let hasOverdueInvoices: Bool

    enum CodingKeys: String, CodingKey {
        case planV3 = "plan_v3"
        case subscriptionPeriod = "subscription_period"
        case usage
        case hasOverdueInvoices = "has_overdue_invoices"
    }
}

public struct ZedSubscriptionPeriod: Decodable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

public struct ZedCurrentUsage: Decodable, Equatable, Sendable {
    public let editPredictions: ZedUsageData

    enum CodingKeys: String, CodingKey {
        case editPredictions = "edit_predictions"
    }
}

public struct ZedUsageData: Decodable, Equatable, Sendable {
    public let used: Int
    public let limit: ZedUsageLimit
}

public enum ZedUsageLimit: Equatable, Sendable {
    case limited(Int)
    case unlimited
}

extension ZedUsageLimit: Decodable {
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let string = try? single.decode(String.self), string == "unlimited" {
                self = .unlimited
                return
            }
            if let value = try? single.decode(Int.self) {
                self = .limited(value)
                return
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Int.self, forKey: .limited) {
            self = .limited(value)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unrecognized Zed usage limit"))
    }

    private enum CodingKeys: String, CodingKey {
        case limited
    }
}

public struct ZedCredentials: Equatable, Sendable {
    public let userID: String
    public let accessToken: String

    public init(userID: String, accessToken: String) {
        self.userID = userID
        self.accessToken = accessToken
    }

    public var authorizationHeader: String {
        "\(self.userID) \(self.accessToken)"
    }
}

public struct ZedUsageSnapshot: Sendable, Equatable {
    public let response: ZedAuthenticatedUserResponse
    public let updatedAt: Date

    public init(response: ZedAuthenticatedUserResponse, updatedAt: Date = Date()) {
        self.response = response
        self.updatedAt = updatedAt
    }
}

// MARK: - Errors

public enum ZedStatusProbeError: LocalizedError, Sendable, Equatable {
    case notSupported
    case notSignedIn
    case keychainUnavailable
    case networkError(String)
    case httpError(Int)
    case unauthorized
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            "Zed is only supported on macOS."
        case .notSignedIn:
            "Not signed in to Zed. Sign in from the Zed editor app (GitHub), not just the browser dashboard."
        case .keychainUnavailable:
            "Could not read Zed credentials from the Keychain. Grant CodexBar Keychain access or sign in to Zed again."
        case let .networkError(message):
            "Zed cloud API request failed: \(message)"
        case let .httpError(status):
            "Zed cloud API returned HTTP \(status)."
        case .unauthorized:
            "Zed credentials are invalid or expired. Sign in to Zed again."
        case let .parseFailed(message):
            "Could not parse Zed account response: \(message)"
        }
    }
}

// MARK: - Settings

public struct ZedClientSettings: Sendable, Equatable {
    public let credentialsURL: String?
    public let serverURL: String?

    public init(credentialsURL: String?, serverURL: String?) {
        self.credentialsURL = credentialsURL
        self.serverURL = serverURL
    }

    public var keychainServiceURL: String {
        let trimmedCredentials = self.credentialsURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCredentials, !trimmedCredentials.isEmpty {
            return trimmedCredentials
        }
        let trimmedServer = self.serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedServer, !trimmedServer.isEmpty {
            return trimmedServer
        }
        return ZedStatusProbe.defaultKeychainServiceURL
    }

    public static func load(from url: URL = ZedStatusProbe.defaultSettingsURL) -> ZedClientSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct Payload: Decodable {
            let credentialsURL: String?
            let serverURL: String?

            enum CodingKeys: String, CodingKey {
                case credentialsURL = "credentials_url"
                case serverURL = "server_url"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return ZedClientSettings(
            credentialsURL: payload.credentialsURL,
            serverURL: payload.serverURL)
    }
}

// MARK: - Credentials

public protocol ZedCredentialsReading: Sendable {
    func loadCredentials(serviceURL: String) throws -> ZedCredentials?
}

#if os(macOS)
import Security

public struct ZedKeychainCredentialsReader: ZedCredentialsReading, Sendable {
    public init() {}

    public func loadCredentials(serviceURL: String) throws -> ZedCredentials? {
        if let credentials = try self.loadInternetPasswordCredentials(server: serviceURL) {
            return credentials
        }
        return try self.loadGenericPasswordCredentials(service: serviceURL)
    }

    private func loadInternetPasswordCredentials(server: String) throws -> ZedCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        return try self.credentials(from: query)
    }

    private func loadGenericPasswordCredentials(service: String) throws -> ZedCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        return try self.credentials(from: query)
    }

    private func credentials(from query: [String: Any]) throws -> ZedCredentials? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem:
            throw ZedStatusProbeError.keychainUnavailable
        default:
            throw ZedStatusProbeError.keychainUnavailable
        }

        guard let item = result as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let tokenData: Data? = if let data = item[kSecValueData as String] as? Data {
            data
        } else {
            nil
        }
        guard let tokenData,
              let accessToken = String(data: tokenData, encoding: .utf8),
              !accessToken.isEmpty
        else {
            return nil
        }

        return ZedCredentials(userID: account, accessToken: accessToken)
    }
}
#else
public struct ZedKeychainCredentialsReader: ZedCredentialsReading, Sendable {
    public init() {}

    public func loadCredentials(serviceURL _: String) throws -> ZedCredentials? {
        throw ZedStatusProbeError.notSupported
    }
}
#endif

// MARK: - Probe

public struct ZedStatusProbe: Sendable {
    public static let defaultKeychainServiceURL = "https://zed.dev"
    public static let cloudAPIURL = URL(string: "https://cloud.zed.dev/client/users/me")!

    public static var defaultSettingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Zed/settings.json")
    }

    private static let logger = CodexBarLog.logger(LogCategories.zed)

    private let credentialsReader: any ZedCredentialsReading
    private let transport: any ProviderHTTPTransport
    private let settingsLoader: @Sendable () -> ZedClientSettings?

    public init(
        credentialsReader: any ZedCredentialsReading = ZedKeychainCredentialsReader(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        settingsLoader: @escaping @Sendable () -> ZedClientSettings? = { ZedClientSettings.load() })
    {
        self.credentialsReader = credentialsReader
        self.transport = transport
        self.settingsLoader = settingsLoader
    }

    public func fetch() async throws -> ZedUsageSnapshot {
        let settings = self.settingsLoader()
        let serviceURL = settings?.keychainServiceURL ?? Self.defaultKeychainServiceURL
        guard let credentials = try self.credentialsReader.loadCredentials(serviceURL: serviceURL) else {
            throw ZedStatusProbeError.notSignedIn
        }

        let response = try await self.fetchAuthenticatedUser(credentials: credentials)
        return ZedUsageSnapshot(response: response)
    }

    public func fetchAuthenticatedUser(credentials: ZedCredentials) async throws -> ZedAuthenticatedUserResponse {
        var request = URLRequest(url: Self.cloudAPIURL)
        request.httpMethod = "GET"
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let httpResponse: ProviderHTTPResponse
        do {
            httpResponse = try await self.transport.response(for: request)
        } catch {
            Self.logger.debug("Zed cloud API transport failed: \(error.localizedDescription)")
            throw ZedStatusProbeError.networkError(error.localizedDescription)
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponse(httpResponse.data)
        case 401, 403:
            throw ZedStatusProbeError.unauthorized
        default:
            throw ZedStatusProbeError.httpError(httpResponse.statusCode)
        }
    }

    public static func parseResponse(_ data: Data) throws -> ZedAuthenticatedUserResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseISO8601Date(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(value)")
        }
        do {
            return try decoder.decode(ZedAuthenticatedUserResponse.self, from: data)
        } catch {
            throw ZedStatusProbeError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

// MARK: - UsageSnapshot mapping

extension ZedUsageSnapshot {
    public func toUsageSnapshot(
        tokenBilling: ZedTokenBillingSnapshot? = nil,
        dashboardCookieSource: ProviderCookieSource = .off,
        billingError: String? = nil) -> UsageSnapshot
    {
        let plan = self.response.plan
        let user = self.response.user

        let primary = Self.makeEditPredictionsWindow(
            used: plan.usage.editPredictions.used,
            limit: plan.usage.editPredictions.limit)

        let secondary = plan.subscriptionPeriod.map { period in
            RateWindow(
                usedPercent: Self.billingCycleUsedPercent(startedAt: period.startedAt, endedAt: period.endedAt),
                windowMinutes: nil,
                resetsAt: period.endedAt,
                resetDescription: Self.formatResetDescription(period.endedAt))
        }

        var extraRateWindows = Self.makeTokenBillingWindows(
            tokenBilling: tokenBilling,
            rawPlan: plan.planV3,
            fallbackPeriodEnd: plan.subscriptionPeriod?.endedAt,
            dashboardCookieSource: dashboardCookieSource,
            billingError: billingError)
        if plan.hasOverdueInvoices {
            extraRateWindows.append(NamedRateWindow(
                id: "zed.overdue-invoices",
                title: "Billing",
                window: RateWindow(
                    usedPercent: 100,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "Overdue invoices"),
                usageKnown: false))
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .zed,
            accountEmail: user.githubLogin.nilIfEmpty,
            accountOrganization: user.name?.nilIfEmpty,
            loginMethod: Self.displayPlanName(plan.planV3))

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: extraRateWindows.isEmpty ? nil : extraRateWindows,
            subscriptionRenewsAt: plan.subscriptionPeriod?.endedAt,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func makeTokenBillingWindows(
        tokenBilling: ZedTokenBillingSnapshot?,
        rawPlan: String,
        fallbackPeriodEnd: Date?,
        dashboardCookieSource: ProviderCookieSource,
        billingError: String?) -> [NamedRateWindow]
    {
        guard let tokenBilling, let spentUSD = tokenBilling.spentUSD else {
            if dashboardCookieSource != .off, let billingError, !billingError.isEmpty {
                return [
                    NamedRateWindow(
                        id: "zed.token-billing-error",
                        title: "Token credits",
                        window: RateWindow(
                            usedPercent: 0,
                            windowMinutes: nil,
                            resetsAt: fallbackPeriodEnd,
                            resetDescription: billingError),
                        usageKnown: false),
                ]
            }

            let placeholderNote = "Sign in on dashboard or enable cookies"
            var windows = [
                NamedRateWindow(
                    id: "zed.token-spend-note",
                    title: "Token spend",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: placeholderNote),
                    usageKnown: true),
            ]
            if let tokenCreditsLabel = Self.includedTokenCreditsLabel(for: rawPlan) {
                windows.append(NamedRateWindow(
                    id: "zed.token-credits",
                    title: "Token credits",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: nil,
                        resetsAt: fallbackPeriodEnd,
                        resetDescription: tokenCreditsLabel),
                    usageKnown: true))
            }
            return windows
        }

        let includedUSD = tokenBilling.includedUSD ?? Self.includedTokenCreditsUSD(for: rawPlan)
        let totalLimit = Self.billingDenominator(
            includedUSD: includedUSD,
            spendLimitUSD: tokenBilling.spendLimitUSD)
        let usedPercent = totalLimit.map { max(0, min(100, spentUSD / $0 * 100)) } ?? 0

        return [
            NamedRateWindow(
                id: "zed.token-credits",
                title: "Token credits",
                window: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: tokenBilling.periodEnd ?? fallbackPeriodEnd,
                    resetDescription: Self.billingDescription(
                        spentUSD: spentUSD,
                        includedUSD: includedUSD,
                        totalLimitUSD: totalLimit)),
                usageKnown: true),
        ]
    }

    private static func billingDenominator(includedUSD: Double?, spendLimitUSD: Double?) -> Double? {
        let candidates = [includedUSD, spendLimitUSD]
            .compactMap(\.self)
            .filter { $0 > 0 }
        return candidates.max()
    }

    private static func billingDescription(
        spentUSD: Double,
        includedUSD: Double?,
        totalLimitUSD: Double?) -> String
    {
        let spent = Self.formatUSD(spentUSD)
        if let includedUSD, totalLimitUSD == includedUSD {
            return "\(spent) of \(Self.formatUSD(includedUSD)) included"
        }
        if let totalLimitUSD {
            return "\(spent) / \(Self.formatUSD(totalLimitUSD))"
        }
        return "\(spent) spent"
    }

    private static func formatUSD(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func makeEditPredictionsWindow(used: Int, limit: ZedUsageLimit) -> RateWindow? {
        switch limit {
        case .unlimited:
            return RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "Unlimited")
        case let .limited(total):
            guard total > 0 else { return nil }
            let clampedUsed = max(0, min(total, used))
            let usedPercent = Double(clampedUsed) / Double(total) * 100.0
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "\(clampedUsed) / \(total) predictions")
        }
    }

    public static func displayPlanName(_ rawPlan: String) -> String {
        switch rawPlan.lowercased() {
        case "zed_free": "Zed Free"
        case "zed_pro": "Zed Pro"
        case "zed_pro_trial": "Zed Pro Trial"
        case "zed_student": "Zed Student"
        case "zed_business": "Zed Business"
        default:
            rawPlan
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst().lowercased()
                }
                .joined(separator: " ")
        }
    }

    static func includedTokenCreditsLabel(for rawPlan: String) -> String? {
        switch rawPlan.lowercased() {
        case "zed_pro":
            "$5 included · live spend on dashboard"
        case "zed_student":
            "$10 included · live spend on dashboard"
        case "zed_pro_trial":
            "$20 trial credits · live spend on dashboard"
        default:
            nil
        }
    }

    private static func includedTokenCreditsUSD(for rawPlan: String) -> Double? {
        switch rawPlan.lowercased() {
        case "zed_pro": 5
        case "zed_student": 10
        case "zed_pro_trial": 20
        default: nil
        }
    }

    private static func billingCycleUsedPercent(startedAt: Date, endedAt: Date) -> Double {
        let now = Date()
        let total = endedAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(startedAt)
        return max(0, min(100, elapsed / total * 100))
    }

    private static func formatResetDescription(_ date: Date) -> String? {
        let now = Date()
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Cycle ended" }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "Cycle ends in \(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "Cycle ends in \(hours)h \(minutes)m"
        } else {
            return "Cycle ends in \(minutes)m"
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
