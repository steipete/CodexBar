import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MiMoSettingsError: LocalizedError, Sendable {
    case missingCookie
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Xiaomi MiMo browser session found. Log in at platform.xiaomimimo.com first."
        case .invalidCookie:
            "Xiaomi MiMo requires the api-platform_serviceToken and userId cookies."
        }
    }
}

public enum MiMoUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case loginRequired
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Xiaomi MiMo browser session expired. Log in again."
        case .loginRequired:
            "Xiaomi MiMo login required."
        case let .parseFailed(message):
            "Could not parse Xiaomi MiMo balance: \(message)"
        case let .networkError(message):
            "Xiaomi MiMo request failed: \(message)"
        }
    }
}

public enum MiMoSettingsReader {
    public static let apiURLKey = "MIMO_API_URL"

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[self.apiURLKey],
           let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme, !scheme.isEmpty
        {
            return url
        }
        return URL(string: "https://platform.xiaomimimo.com/api/v1")!
    }
}

public enum MiMoUsageFetcher {
    private static let requestTimeout: TimeInterval = 15

    public static func fetchUsage(
        cookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> MiMoUsageSnapshot
    {
        guard let normalizedCookie = MiMoCookieHeader.normalizedHeader(from: cookieHeader) else {
            throw MiMoSettingsError.invalidCookie
        }

        let url = MiMoSettingsReader.apiURL(environment: environment).appendingPathComponent("balance")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(normalizedCookie, forHTTPHeaderField: "Cookie")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("UTC+01:00", forHTTPHeaderField: "x-timeZone")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiMoUsageError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw MiMoUsageError.loginRequired
        case 403:
            throw MiMoUsageError.invalidCredentials
        default:
            throw MiMoUsageError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return try self.parseUsageSnapshot(from: data, now: now)
    }

    static func parseUsageSnapshot(from data: Data, now: Date = Date()) throws -> MiMoUsageSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(Response.self, from: data)

        guard response.code == 0 else {
            let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            if response.code == 401 {
                throw MiMoUsageError.loginRequired
            }
            if response.code == 403 {
                throw MiMoUsageError.invalidCredentials
            }
            throw MiMoUsageError.parseFailed(message?.isEmpty == false ? message! : "code \(response.code)")
        }

        guard let data = response.data else {
            throw MiMoUsageError.parseFailed("Missing balance payload")
        }
        guard let balance = Double(data.balance) else {
            throw MiMoUsageError.parseFailed("Invalid balance value")
        }

        let currency = data.currency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currency.isEmpty else {
            throw MiMoUsageError.parseFailed("Missing currency")
        }

        return MiMoUsageSnapshot(balance: balance, currency: currency, updatedAt: now)
    }

    private struct Response: Decodable {
        let code: Int
        let message: String?
        let data: Payload?
    }

    private struct Payload: Decodable {
        let balance: String
        let currency: String
    }
}
