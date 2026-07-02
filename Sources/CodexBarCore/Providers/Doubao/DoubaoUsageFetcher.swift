import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DoubaoUsageSnapshot: Sendable {
    public let remainingRequests: Int
    public let limitRequests: Int
    public let resetTime: Date?
    public let updatedAt: Date
    public let apiKeyValid: Bool
    public let totalTokens: Int?
    public let requestLimitsReliable: Bool
    public let codingPlanUsage: DoubaoCodingPlanUsage?
    public init(
        remainingRequests: Int,
        limitRequests: Int,
        resetTime: Date?,
        updatedAt: Date,
        apiKeyValid: Bool = false,
        totalTokens: Int? = nil,
        requestLimitsReliable: Bool = true,
        codingPlanUsage: DoubaoCodingPlanUsage? = nil)
    {
        self.remainingRequests = remainingRequests
        self.limitRequests = limitRequests
        self.resetTime = resetTime
        self.updatedAt = updatedAt
        self.apiKeyValid = apiKeyValid
        self.totalTokens = totalTokens
        self.requestLimitsReliable = requestLimitsReliable
        self.codingPlanUsage = codingPlanUsage
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        if let codingPlanUsage {
            return codingPlanUsage.toUsageSnapshot(updatedAt: self.updatedAt)
        }

        let primary: RateWindow?
        if self.limitRequests > 0, self.requestLimitsReliable {
            let used = max(0, self.limitRequests - self.remainingRequests)
            primary = RateWindow(
                usedPercent: min(100, max(0, Double(used) / Double(self.limitRequests) * 100)),
                windowMinutes: nil,
                resetsAt: self.resetTime,
                resetDescription: "\(used)/\(self.limitRequests) requests")
        } else if self.apiKeyValid {
            // Ark can return successful requests without a trustworthy request-limit window.
            // Omitting the window prevents the UI from presenting unknown usage as 100% left.
            primary = nil
        } else {
            primary = RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: self.resetTime,
                resetDescription: "No usage data")
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .doubao,
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

public struct DoubaoCodingPlanUsage: Sendable, Equatable {
    public struct Quota: Sendable, Equatable {
        public let level: String
        public let percent: Double
        public let resetTime: Date?

        public init(level: String, percent: Double, resetTime: Date?) {
            self.level = level
            self.percent = percent
            self.resetTime = resetTime
        }
    }

    public let status: String?
    public let updateTime: Date?
    public let quotas: [Quota]

    public init(status: String?, updateTime: Date?, quotas: [Quota]) {
        self.status = status
        self.updateTime = updateTime
        self.quotas = quotas
    }

    public func toUsageSnapshot(updatedAt: Date) -> UsageSnapshot {
        let primary = self.rateWindow(levels: ["session", "5-hour", "five_hour"], minutes: 5 * 60)
        let secondary = self.rateWindow(levels: ["weekly", "week"], minutes: 7 * 24 * 60)
        let tertiary = self.rateWindow(levels: ["monthly", "month"], minutes: 30 * 24 * 60)
        let identity = ProviderIdentitySnapshot(
            providerID: .doubao,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.status)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: nil,
            updatedAt: self.updateTime ?? updatedAt,
            identity: identity)
    }

    private func rateWindow(levels: Set<String>, minutes: Int) -> RateWindow? {
        guard let quota = self.quotas.first(where: { levels.contains($0.level.lowercased()) }) else {
            return nil
        }
        let percent = min(100, max(0, quota.percent))
        return RateWindow(
            usedPercent: percent,
            windowMinutes: minutes,
            resetsAt: quota.resetTime,
            resetDescription: nil)
    }
}

public enum DoubaoUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(Int, String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Doubao API key (ARK_API_KEY)."
        case let .networkError(message):
            "Doubao network error: \(message)"
        case let .apiError(code, message):
            "Doubao API error (\(code)): \(message)"
        case let .parseFailed(message):
            "Failed to parse Doubao response: \(message)"
        }
    }
}

public struct DoubaoUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.doubaoUsage)
    private static let apiURL = URL(string: "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions")!
    private static let codingPlanAPIURL = URL(
        string: "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")!

    /// Models to probe, ordered by likelihood. We try multiple models because
    /// different key types may not have access to every model.
    private static let probeModels = [
        "doubao-seed-2.0-code",
        "doubao-1.5-pro-32k",
        "doubao-lite-32k",
    ]

    private struct ProbeResult {
        let snapshot: DoubaoUsageSnapshot
        let statusCode: Int

        var hasAmbiguousZeroRemaining: Bool {
            self.statusCode == 200
                && self.snapshot.requestLimitsReliable
                && self.snapshot.limitRequests > 0
                && self.snapshot.remainingRequests == 0
        }
    }

    public static func fetchUsage(
        apiKey: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> DoubaoUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoubaoUsageError.missingCredentials
        }

        var lastError: Error?
        for model in self.probeModels {
            do {
                let result = try await self.probe(apiKey: apiKey, model: model, transport: transport)
                guard result.hasAmbiguousZeroRemaining else {
                    return result.snapshot
                }

                return try await self.confirmAmbiguousZeroRemaining(
                    initial: result,
                    apiKey: apiKey,
                    model: model,
                    transport: transport)
            } catch let error as DoubaoUsageError {
                if case let .apiError(code, _) = error, code == 404 || code == 403 {
                    Self.log.debug("Doubao probe model \(model) unavailable (\(code)), trying next")
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? DoubaoUsageError.apiError(0, "All probe models failed")
    }

    public static func fetchCodingPlanUsage(
        credentials: DoubaoCodingPlanCredentials,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        date: Date = Date()) async throws -> DoubaoUsageSnapshot
    {
        guard !credentials.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DoubaoUsageError.missingCredentials
        }

        let body = Data()
        var request = URLRequest(url: self.codingPlanAPIURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        DoubaoVolcengineSigner.sign(
            request: &request,
            body: body,
            credentials: credentials,
            date: date)

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            let summary = Self.apiErrorSummary(statusCode: response.statusCode, data: response.data)
            Self.log.error("Doubao coding plan API returned \(response.statusCode): \(summary)")
            throw DoubaoUsageError.apiError(response.statusCode, summary)
        }

        let codingPlanUsage = try self.decodeCodingPlanUsage(from: response.data)
        return DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: codingPlanUsage.updateTime ?? date,
            apiKeyValid: true,
            codingPlanUsage: codingPlanUsage)
    }

    static func decodeCodingPlanUsage(from data: Data) throws -> DoubaoCodingPlanUsage {
        let response: CodingPlanUsageResponse
        do {
            response = try JSONDecoder().decode(CodingPlanUsageResponse.self, from: data)
        } catch {
            throw DoubaoUsageError.parseFailed(error.localizedDescription)
        }
        let usage = response.result
        let quotas = usage.quotaUsage.map { quota in
            DoubaoCodingPlanUsage.Quota(
                level: quota.level,
                percent: quota.percent,
                resetTime: self.date(fromEpoch: quota.resetTimestamp))
        }
        return DoubaoCodingPlanUsage(
            status: usage.status,
            updateTime: self.date(fromEpoch: usage.updateTimestamp),
            quotas: quotas)
    }

    private static func date(fromEpoch timestamp: TimeInterval?) -> Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func confirmAmbiguousZeroRemaining(
        initial: ProbeResult,
        apiKey: String,
        model: String,
        transport: any ProviderHTTPTransport) async throws -> DoubaoUsageSnapshot
    {
        do {
            let confirmation = try await self.probe(apiKey: apiKey, model: model, transport: transport)
            // This path starts only after a complete HTTP 200 request-limit pair
            // reported zero. An immediate 429 confirms that exhausted state even
            // when Ark omits the headers from the throttle response.
            if confirmation.statusCode == 429 {
                return confirmation.snapshot.requestLimitsReliable
                    ? confirmation.snapshot
                    : initial.snapshot
            }
            guard confirmation.hasAmbiguousZeroRemaining else {
                return confirmation.snapshot
            }

            Self.log.warning(
                """
                Doubao Ark returned limit=\(confirmation.snapshot.limitRequests) remaining=0 \
                with HTTP 200 twice; treating request-limit headers as unreliable.
                """)
            return DoubaoUsageSnapshot(
                remainingRequests: confirmation.snapshot.remainingRequests,
                limitRequests: confirmation.snapshot.limitRequests,
                resetTime: confirmation.snapshot.resetTime,
                updatedAt: confirmation.snapshot.updatedAt,
                apiKeyValid: confirmation.snapshot.apiKeyValid,
                totalTokens: confirmation.snapshot.totalTokens,
                requestLimitsReliable: false)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            self.log.warning(
                """
                Doubao zero-remaining confirmation failed; preserving the initial exhausted state: \
                \(error.localizedDescription)
                """)
            return initial.snapshot
        }
    }

    private static func probe(
        apiKey: String,
        model: String,
        transport: any ProviderHTTPTransport) async throws -> ProbeResult
    {
        var request = URLRequest(url: self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "hi"],
            ] as [[String: Any]],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await transport.response(for: request)
        let data = response.data

        // Accept both 200 (success) and 429 (rate limited) – both carry rate limit headers.
        guard response.statusCode == 200 || response.statusCode == 429 else {
            let summary = Self.apiErrorSummary(statusCode: response.statusCode, data: data)
            Self.log.error("Doubao API returned \(response.statusCode): \(summary)")
            throw DoubaoUsageError.apiError(response.statusCode, summary)
        }

        let headers = response.response.allHeaderFields
        let remaining = Self.intHeader(headers, "x-ratelimit-remaining-requests")
        let limit = Self.intHeader(headers, "x-ratelimit-limit-requests")
        let resetString = Self.stringHeader(headers, "x-ratelimit-reset-requests")

        let resetTime: Date? = resetString.flatMap(Self.parseResetTime)

        var totalTokens: Int?
        if remaining == nil, limit == nil,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usage = json["usage"] as? [String: Any]
        {
            totalTokens = usage["total_tokens"] as? Int
        }

        // 429 means the key is valid but rate-limited; treat it as valid so the UI
        // shows "Active" instead of "No usage data" when headers are absent.
        let keyValid = response.statusCode == 200 || response.statusCode == 429
        // A request-limit header on 429 identifies request-bucket exhaustion even
        // when Ark omits remaining. A bare 429 may describe another throttle.
        let requestLimitsReliable = response.statusCode == 429
            ? limit != nil
            : limit != nil && remaining != nil

        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: remaining ?? 0,
            limitRequests: limit ?? 0,
            resetTime: resetTime,
            updatedAt: Date(),
            apiKeyValid: keyValid,
            totalTokens: totalTokens,
            requestLimitsReliable: requestLimitsReliable)

        Self.log.debug(
            """
            Doubao usage parsed remaining=\(snapshot.remainingRequests) \
            limit=\(snapshot.limitRequests) valid=\(snapshot.apiKeyValid)
            """)

        return ProbeResult(snapshot: snapshot, statusCode: response.statusCode)
    }

    private static func stringHeader(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        if let value = headers[name] as? String { return value }
        for (key, val) in headers {
            if let keyStr = key as? String,
               keyStr.caseInsensitiveCompare(name) == .orderedSame,
               let valStr = val as? String
            {
                return valStr
            }
        }
        return nil
    }

    private static func intHeader(_ headers: [AnyHashable: Any], _ name: String) -> Int? {
        if let value = headers[name] as? String, let int = Int(value) {
            return int
        }
        if let value = headers[name.lowercased()] as? String, let int = Int(value) {
            return int
        }
        for (key, val) in headers {
            if let keyStr = key as? String,
               keyStr.lowercased() == name.lowercased(),
               let valStr = val as? String,
               let int = Int(valStr)
            {
                return int
            }
        }
        return nil
    }

    private static func parseResetTime(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) { return date }
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]
        if let date = isoFallback.date(from: trimmed) { return date }

        var seconds: TimeInterval = 0
        let pattern = /(\d+)([dhms])/
        for match in trimmed.matches(of: pattern) {
            guard let num = Double(match.1) else { continue }
            switch match.2 {
            case "d": seconds += num * 86400
            case "h": seconds += num * 3600
            case "m": seconds += num * 60
            case "s": seconds += num
            default: break
            }
        }
        if seconds > 0 {
            return Date().addingTimeInterval(seconds)
        }

        if let secs = TimeInterval(trimmed) {
            return Date().addingTimeInterval(secs)
        }

        return nil
    }

    private static func apiErrorSummary(statusCode: Int, data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let json = root as? [String: Any]
        else {
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                return self.compactText(text)
            }
            return "Unexpected response body (\(data.count) bytes)."
        }

        // Volcengine Top OpenAPI error shape: { "ResponseMetadata": { "Error": { "Code": ..., "Message": ... } } }
        if let metadata = json["ResponseMetadata"] as? [String: Any],
           let volcError = metadata["Error"] as? [String: Any]
        {
            let code = (volcError["Code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (volcError["Message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (code?.isEmpty == false ? code : nil, message?.isEmpty == false ? message : nil) {
            case let (code?, message?):
                return Self.compactText("\(code): \(message)")
            case let (code?, nil):
                return Self.compactText(code)
            case let (nil, message?):
                return Self.compactText(message)
            case (nil, nil):
                break
            }
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String
        {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return Self.compactText(trimmed) }
        }

        if let message = json["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return Self.compactText(trimmed) }
        }

        return "HTTP \(statusCode) (\(data.count) bytes)."
    }

    private static func compactText(_ text: String, maxLength: Int = 200) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxLength { return collapsed }
        let limitIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return "\(collapsed[..<limitIndex])..."
    }

    private struct CodingPlanUsageResponse: Decodable {
        let result: ResultPayload

        private enum CodingKeys: String, CodingKey {
            case result = "Result"
        }
    }

    private struct ResultPayload: Decodable {
        let status: String?
        let updateTimestamp: TimeInterval?
        let quotaUsage: [QuotaPayload]

        private enum CodingKeys: String, CodingKey {
            case status = "Status"
            case updateTimestamp = "UpdateTimestamp"
            case quotaUsage = "QuotaUsage"
        }
    }

    private struct QuotaPayload: Decodable {
        let level: String
        let percent: Double
        let resetTimestamp: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case level = "Level"
            case percent = "Percent"
            case resetTimestamp = "ResetTimestamp"
        }
    }
}
