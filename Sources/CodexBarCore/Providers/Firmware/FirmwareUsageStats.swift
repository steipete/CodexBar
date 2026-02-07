import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct FirmwareQuotaResponse: Decodable {
    let used: Double
    let reset: String?
}

public struct FirmwareQuotaSnapshot: Sendable {
    public let usedRatio: Double
    public let resetsAt: Date?
    public let updatedAt: Date

    public init(usedRatio: Double, resetsAt: Date?, updatedAt: Date) {
        self.usedRatio = usedRatio
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
    }
}

extension FirmwareQuotaSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent = max(0, min(100, self.usedRatio * 100))
        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 300,
            resetsAt: self.resetsAt,
            resetDescription: self.resetsAt == nil ? "5 hour window" : nil)

        let identity = ProviderIdentitySnapshot(
            providerID: .firmware,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public struct FirmwareQuotaFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.firmwareUsage)
    private static let quotaURL = URL(string: "https://app.firmware.ai/api/v1/quota")!

    public static func fetchUsage(apiKey: String, now: Date = Date()) async throws -> FirmwareQuotaSnapshot {
        guard !apiKey.isEmpty else {
            throw FirmwareUsageError.invalidCredentials
        }

        var request = URLRequest(url: Self.quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FirmwareUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("Firmware API returned \(httpResponse.statusCode): \(errorMessage)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw FirmwareUsageError.invalidCredentials
            }
            throw FirmwareUsageError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        do {
            let decoder = JSONDecoder()
            let parsed = try decoder.decode(FirmwareQuotaResponse.self, from: data)
            let resetDate = parsed.reset.flatMap { FirmwareTimestampParser.parse($0) }
            return FirmwareQuotaSnapshot(usedRatio: parsed.used, resetsAt: resetDate, updatedAt: now)
        } catch {
            Self.log.error("Firmware parsing error: \(error.localizedDescription)")
            throw FirmwareUsageError.parseFailed(error.localizedDescription)
        }
    }
}

private final class FirmwareISO8601FormatterBox: @unchecked Sendable {
    let lock = NSLock()
    let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private enum FirmwareTimestampParser {
    static let box = FirmwareISO8601FormatterBox()

    static func parse(_ text: String) -> Date? {
        self.box.lock.lock()
        defer { self.box.lock.unlock() }
        return self.box.withFractional.date(from: text) ?? self.box.plain.date(from: text)
    }
}

public enum FirmwareUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid Firmware API credentials"
        case let .networkError(message):
            "Firmware network error: \(message)"
        case let .apiError(message):
            "Firmware API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Firmware response: \(message)"
        }
    }
}
