import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LongCatUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.longcatAPI)
    private static let host = "https://longcat.chat"

    private static let userCurrentPath = "/api/v1/user-current"
    private static let tokenUsagePath = "/api/lc-platform/v1/tokenUsage"
    private static let pendingFuelPath = "/api/lc-platform/v1/pending-fuel-packages"

    public static func fetchUsage(cookieHeader: String, now: Date = Date()) async throws -> LongCatUsageSnapshot {
        // Account name. The user-current payload also carries a session token and
        // phone number, so its body is never logged. Failure here is non-fatal.
        var account: [String: Any]?
        if let data = try await self.get(self.userCurrentPath, cookieHeader: cookieHeader, required: true) {
            account = (try? LongCatEnvelope.unwrap(self.json(data))) as? [String: Any]
        }

        var usage: [String: Any]?
        if let data = try? await self.get(self.tokenUsagePath, cookieHeader: cookieHeader, required: false) {
            self.logRawShape(self.tokenUsagePath, data)
            usage = (try? LongCatEnvelope.unwrap(self.json(data))) as? [String: Any]
        }

        var fuel: [String: Any]?
        if let data = try? await self.get(self.pendingFuelPath, cookieHeader: cookieHeader, required: false) {
            self.logRawShape(self.pendingFuelPath, data)
            fuel = (try? LongCatEnvelope.unwrap(self.json(data))) as? [String: Any]
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
            snapshot.freeQuota = LongCatJSON.double(usage["freeAvailableToken"])
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
            if let value = LongCatJSON.firstNumber(
                in: package,
                keys: ["availableToken", "remainToken", "remainQuota", "remainingQuota", "remain", "availableQuota"])
            {
                remaining += value
                sawRemaining = true
            }
            if let expiry = self.parseDate(
                package["expireTime"] ?? package["expiredTime"] ?? package["expireAt"]
                    ?? package["gmtExpire"] ?? package["expireDate"])
            {
                if nearestExpiry == nil || expiry < nearestExpiry! { nearestExpiry = expiry }
            }
        }

        if let total, total > 0 {
            snapshot.fuelPackTotal = total
            snapshot.fuelPackRemaining = sawRemaining ? remaining : total
        }
        snapshot.nearestFuelExpiry = nearestExpiry
    }

    // MARK: - HTTP

    private static func get(_ path: String, cookieHeader: String, required: Bool) async throws -> Data? {
        guard let url = URL(string: self.host + path) else {
            throw LongCatAPIError.invalidRequest("bad URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(self.host, forHTTPHeaderField: "Origin")
        request.setValue("\(self.host)/platform/usage", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let response = try await ProviderHTTPClient.shared.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
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

    /// Logs the (non-sensitive) response shape to help future debugging. Never
    /// called for user-current, whose body carries a session token + phone.
    private static func logRawShape(_ path: String, _ data: Data) {
        guard let body = String(data: data, encoding: .utf8) else { return }
        Self.log.debug("LongCat \(path) raw: \(body.prefix(1200))")
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = LongCatJSON.double(value) {
            let seconds = number > 1_000_000_000_000 ? number / 1000 : number
            if seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        }
        if let string = LongCatJSON.string(value) {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) { return date }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
