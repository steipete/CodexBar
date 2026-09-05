import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MuseUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case keychainUnavailable
    case paymentRequired
    case noSubscription
    case apiError(Int)
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Muse Code login not found. Run `muse login`, then refresh CodexBar."
        case .invalidCredentials:
            "Muse Code login was rejected. Run `muse login` again."
        case .keychainUnavailable:
            "Muse Code credentials are in Keychain but could not be read without a prompt."
        case .paymentRequired:
            "Muse Code requires a payment method. Finish billing at https://dev.meta.ai"
        case .noSubscription:
            "No Muse Code subscription is active on this login."
        case let .apiError(statusCode):
            "Muse Code API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse Muse Code subscription usage: \(message)"
        case let .networkError(message):
            "Muse Code network error: \(message)"
        }
    }
}

public struct MuseUsageSnapshot: Sendable, Equatable {
    public let planName: String?
    public let accountEmail: String?
    public let windowUsedPercent: Double
    public let windowMinutes: Int
    public let windowResetsAt: Date?
    public let weeklyUsedPercent: Double
    public let weeklyResetsAt: Date?
    public let updatedAt: Date

    public init(
        planName: String?,
        accountEmail: String?,
        windowUsedPercent: Double,
        windowMinutes: Int,
        windowResetsAt: Date?,
        weeklyUsedPercent: Double,
        weeklyResetsAt: Date?,
        updatedAt: Date)
    {
        self.planName = planName
        self.accountEmail = accountEmail
        self.windowUsedPercent = windowUsedPercent
        self.windowMinutes = windowMinutes
        self.windowResetsAt = windowResetsAt
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let plan = Self.nonEmpty(self.planName)
        let details: [ProviderDetailSection] = {
            var rows: [ProviderDetailSection.Row] = []
            if let plan {
                rows.append(.makeRow(label: "Plan", value: plan))
            }
            rows.append(.makeRow(
                label: "5 hours",
                value: UsageFormatter.percentString(self.windowUsedPercent)))
            rows.append(.makeRow(
                label: "Weekly",
                value: UsageFormatter.percentString(self.weeklyUsedPercent)))
            return rows.isEmpty ? [] : [.makeSection(title: "Muse Code subscription", rows: rows)]
        }()

        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: self.windowUsedPercent,
                windowMinutes: self.windowMinutes,
                resetsAt: self.windowResetsAt,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: self.weeklyUsedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: self.weeklyResetsAt,
                resetDescription: nil),
            details: details,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .muse,
                accountEmail: Self.nonEmpty(self.accountEmail),
                accountOrganization: nil,
                loginMethod: plan ?? "Muse login"),
            dataConfidence: .exact)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum MuseUsageFetcher {
    public static let mintURL = URL(string: "https://api.meta.ai/muse-code/key")!
    private static let timeoutSeconds: TimeInterval = 15
    private static let apiVersion = "1.0.0"

    public static func fetchUsage(accessToken: String) async throws -> MuseUsageSnapshot {
        try await self.fetchUsage(
            accessToken: accessToken,
            transport: ProviderHTTPClient.shared,
            now: Date())
    }

    static func _fetchUsageForTesting(
        accessToken: String,
        transport: any ProviderHTTPTransport,
        now: Date = Date()) async throws -> MuseUsageSnapshot
    {
        try await self.fetchUsage(accessToken: accessToken, transport: transport, now: now)
    }

    static func _parseMintResponseForTesting(_ data: Data, now: Date = Date()) throws -> MuseUsageSnapshot {
        try self.parseMintResponse(data, now: now)
    }

    private static func fetchUsage(
        accessToken: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> MuseUsageSnapshot
    {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("dca:") else { throw MuseUsageError.invalidCredentials }

        do {
            let response = try await transport.response(
                for: self.request(accessToken: token),
                retryPolicy: .disabled)
            try self.validate(response)
            return try self.parseMintResponse(response.data, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MuseUsageError {
            throw error
        } catch let error as DecodingError {
            throw MuseUsageError.parseFailed("mint response did not parse: \(error)")
        } catch {
            throw MuseUsageError.networkError(error.localizedDescription)
        }
    }

    private static func request(accessToken: String) -> URLRequest {
        var request = URLRequest(url: self.mintURL)
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeoutSeconds
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(self.apiVersion, forHTTPHeaderField: "x-api-version")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validate(_ response: ProviderHTTPResponse) throws {
        switch response.statusCode {
        case 200:
            return
        case 401, 403:
            throw MuseUsageError.invalidCredentials
        default:
            throw MuseUsageError.apiError(response.statusCode)
        }
    }

    private static func parseMintResponse(_ data: Data, now: Date) throws -> MuseUsageSnapshot {
        let mint: MintResponse
        do {
            mint = try JSONDecoder().decode(MintResponse.self, from: data)
        } catch {
            throw MuseUsageError.parseFailed("mint response did not parse: \(error)")
        }

        if mint.requirePayment == true {
            throw MuseUsageError.paymentRequired
        }
        guard mint.isSubsActive == true else {
            throw MuseUsageError.noSubscription
        }
        guard let usage = mint.subsUsage, let window = usage.window, let weekly = usage.weekly else {
            throw MuseUsageError.parseFailed("mint response omitted subs_usage windows")
        }

        return MuseUsageSnapshot(
            planName: mint.subsTierName,
            accountEmail: mint.userEmail,
            windowUsedPercent: max(0, window.usedPercent),
            windowMinutes: max(1, window.windowDurationMins),
            windowResetsAt: self.date(fromUnixSeconds: window.resetsAt),
            weeklyUsedPercent: max(0, weekly.usedPercent),
            weeklyResetsAt: self.date(fromUnixSeconds: weekly.resetsAt),
            updatedAt: now)
    }

    private static func date(fromUnixSeconds value: Double?) -> Date? {
        guard let value, value > 0, value <= Date.distantFuture.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private struct MintResponse: Decodable {
        let requirePayment: Bool?
        let isSubsActive: Bool?
        let userEmail: String?
        let subsTierName: String?
        let subsUsage: SubscriptionUsage?

        enum CodingKeys: String, CodingKey {
            case requirePayment = "require_payment"
            case isSubsActive = "is_subs_active"
            case userEmail = "user_email"
            case subsTierName = "subs_tier_name"
            case subsUsage = "subs_usage"
        }
    }

    private struct SubscriptionUsage: Decodable {
        let window: UsageWindow?
        let weekly: WeeklyWindow?
    }

    private struct UsageWindow: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowDurationMins = "window_duration_mins"
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.usedPercent = try Self.decodeNumber(container, forKey: .usedPercent)
            let minutes = try Self.decodeNumber(container, forKey: .windowDurationMins)
            let rounded = minutes.rounded()
            guard let bounded = Int(exactly: rounded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .windowDurationMins,
                    in: container,
                    debugDescription: "window_duration_mins \(minutes) is not representable as an Int")
            }
            self.windowDurationMins = bounded
            self.resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
                ?? container.decodeIfPresent(Int.self, forKey: .resetsAt).map(Double.init)
        }

        private static func decodeNumber(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys) throws -> Double
        {
            if let value = try? container.decode(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return Double(value)
            }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected a number")
        }
    }

    private struct WeeklyWindow: Decodable {
        let usedPercent: Double
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(Double.self, forKey: .usedPercent) {
                self.usedPercent = value
            } else if let value = try? container.decode(Int.self, forKey: .usedPercent) {
                self.usedPercent = Double(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .usedPercent,
                    in: container,
                    debugDescription: "Expected a number")
            }
            self.resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
                ?? container.decodeIfPresent(Int.self, forKey: .resetsAt).map(Double.init)
        }
    }
}
