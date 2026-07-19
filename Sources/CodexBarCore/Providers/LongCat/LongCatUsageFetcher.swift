import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LongCatUsageFetcher: Sendable {
    private enum Authentication: @unchecked Sendable {
        case header(String)
        case cookies([HTTPCookie])

        func header(for url: URL) -> String? {
            switch self {
            case let .header(value):
                value.isEmpty ? nil : value
            case let .cookies(cookies):
                LongCatCookieHeader.header(from: cookies, for: url)
            }
        }
    }

    private static let log = CodexBarLog.logger(LogCategories.longcatAPI)
    private static let host = "https://longcat.chat"

    private static let userCurrentPath = "/api/v1/user-current"
    private static let tokenUsagePath = "/api/lc-platform/v1/tokenUsage"
    private static let pendingFuelPath = "/api/lc-platform/v1/pending-fuel-packages"

    /// LongCat fetches run on an isolated, ephemeral, cookie-free session so the
    /// console's `Set-Cookie` responses never enter the shared provider cookie jar;
    /// auth is carried solely by the explicit request `Cookie` header. Mirrors the
    /// Sakana provider's isolated transport.
    private static let defaultTransport: ProviderHTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = ProviderHTTPClient.redirectGuardedSession(configuration: configuration)
        return ProviderHTTPClient(session: session)
    }()

    public static func fetchUsage(
        cookieHeader: String,
        transport transportOverride: (any ProviderHTTPTransport)? = nil,
        now: Date = Date()) async throws -> LongCatUsageSnapshot
    {
        try await self.fetchUsage(
            authentication: .header(cookieHeader),
            transport: transportOverride,
            now: now)
    }

    static func fetchUsage(
        cookies: [HTTPCookie],
        transport transportOverride: (any ProviderHTTPTransport)? = nil,
        now: Date = Date()) async throws -> LongCatUsageSnapshot
    {
        try await self.fetchUsage(
            authentication: .cookies(cookies),
            transport: transportOverride,
            now: now)
    }

    private static func fetchUsage(
        authentication: Authentication,
        transport transportOverride: (any ProviderHTTPTransport)?,
        now: Date) async throws -> LongCatUsageSnapshot
    {
        let transport = transportOverride ?? Self.defaultTransport
        // Account name. The user-current payload also carries a session token and
        // phone number, so its body is never logged. This is the required probe:
        // a Meituan envelope with HTTP 200 but code 401/403 surfaces as
        // `.invalidSession` here (via unwrap) so expired cookies are reported
        // rather than masked by an empty snapshot.
        var account: [String: Any]?
        if let data = try await self.get(
            self.userCurrentPath,
            authentication: authentication,
            transport: transport,
            required: true)
        {
            let payload = try LongCatEnvelope.unwrap(self.json(data))
            guard let object = payload as? [String: Any] else {
                throw LongCatAPIError.parseFailed("user-current data was not an object")
            }
            account = object
        }

        guard let usageData = try await self.get(
            self.tokenUsagePath,
            authentication: authentication,
            transport: transport,
            required: true)
        else {
            throw LongCatAPIError.parseFailed("tokenUsage response was empty")
        }
        let usagePayload = try LongCatEnvelope.unwrap(self.json(usageData))
        guard let usage = usagePayload as? [String: Any] else {
            throw LongCatAPIError.parseFailed("tokenUsage data was not an object")
        }
        let canonicalUsage = LongCatJSON.object(usage["usage"]) ?? usage
        guard LongCatJSON.double(canonicalUsage["totalToken"]) != nil else {
            throw LongCatAPIError.parseFailed("tokenUsage data was missing totalToken")
        }

        var fuel: [String: Any]?
        do {
            if let data = try await self.get(
                self.pendingFuelPath,
                authentication: authentication,
                transport: transport,
                required: false)
            {
                let payload = try LongCatEnvelope.unwrap(self.json(data))
                guard let object = payload as? [String: Any] else {
                    throw LongCatAPIError.parseFailed("pending fuel data was not an object")
                }
                fuel = object
            }
        } catch {
            Self.log.error("LongCat supplemental fuel probe failed: \(error.localizedDescription)")
        }

        return self.buildSnapshot(account: account, tokenUsage: usage, pendingFuel: fuel, now: now)
    }

    /// Pure extraction over the unwrapped `data` payloads. Field paths are locked
    /// against captured live responses; see `LongCatProviderTests`.
    static func buildSnapshot(
        account: [String: Any]?,
        tokenUsage: [String: Any]?,
        pendingFuel: [String: Any]?,
        now: Date = Date()) -> LongCatUsageSnapshot
    {
        var snapshot = LongCatUsageSnapshot(updatedAt: now)

        if let account {
            snapshot.accountName = LongCatJSON.string(account["name"]) ?? LongCatJSON.string(account["nickName"])
        }

        // Token quota: data.usage is the canonical aggregate; extData holds the
        // per-model breakdown (LongCat-Flash-Lite, LongCat-2.0-Preview, ...).
        if let tokenUsage {
            let usage = LongCatJSON.object(tokenUsage["usage"]) ?? tokenUsage
            snapshot.totalQuota = LongCatJSON.double(usage["totalToken"])
            snapshot.usedQuota = LongCatJSON.double(usage["usedToken"])
            snapshot.remainingQuota = LongCatJSON.double(usage["availableToken"])
        }

        if let pendingFuel {
            self.applyFuelPackages(pendingFuel, to: &snapshot)
        }

        return snapshot
    }

    private static func applyFuelPackages(_ dict: [String: Any], to snapshot: inout LongCatUsageSnapshot) {
        let total = LongCatJSON.double(dict["totalQuota"])
        let packages = LongCatJSON.array(dict["list"]) ?? []

        var remaining = 0.0
        var sawRemaining = false
        var nearestExpiry: Date?
        for package in packages {
            // Field names are pinned to the shapes captured from live longcat.chat
            // responses (see LongCatProviderTests): a fuel package reports its remaining
            // balance under `availableToken` and its expiry under `expireTime`.
            if let value = LongCatJSON.double(package["availableToken"]) {
                remaining += value
                sawRemaining = true
            }
            if let expiry = self.parseDate(package["expireTime"]) {
                if nearestExpiry == nil || expiry < nearestExpiry! {
                    nearestExpiry = expiry
                }
            }
        }

        if let total, total > 0 {
            snapshot.fuelPackTotal = total
            snapshot.fuelPackRemaining = sawRemaining ? remaining : total
        }
        snapshot.nearestFuelExpiry = nearestExpiry
    }

    // MARK: - HTTP

    private static func get(
        _ path: String,
        authentication: Authentication,
        transport: any ProviderHTTPTransport,
        required: Bool) async throws -> Data?
    {
        guard let url = URL(string: self.host + path) else {
            throw LongCatAPIError.invalidRequest("bad URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let cookieHeader = authentication.header(for: url) else {
            throw LongCatAPIError.missingCookies
        }
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(self.host, forHTTPHeaderField: "Origin")
        request.setValue("\(self.host)/platform/usage", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            // The shared transport's redirect guard drops cross-origin / non-HTTPS
            // hops, so an expired-cookie login redirect surfaces here as the raw 3xx.
            // Classify 3xx (and explicit 401/403) as an invalid session rather than a
            // generic HTTP error, so users see "sign in again" instead of "HTTP 302".
            if response.statusCode == 401 || response.statusCode == 403
                || (300..<400).contains(response.statusCode)
            {
                throw LongCatAPIError.invalidSession
            }
            if required {
                throw LongCatAPIError.apiError("HTTP \(response.statusCode) for \(path)")
            }
            Self.log.error("LongCat \(path) returned \(response.statusCode)")
            return nil
        }
        return response.data
    }

    private static func json(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = LongCatJSON.double(value) {
            let seconds = number > 1_000_000_000_000 ? number / 1000 : number
            if seconds > 1_000_000_000 {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        if let string = LongCatJSON.string(value) {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) {
                return date
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}
