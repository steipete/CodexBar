import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MuseUsageSnapshot: Sendable {
    public let summary: MuseUsageSummary

    public init(summary: MuseUsageSummary) {
        self.summary = summary
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        self.summary.toUsageSnapshot()
    }
}

public struct MuseUsageSummary: Sendable {
    public let balance: Double?
    public let currency: String?
    public let modelCount: Int?
    public let updatedAt: Date

    public init(balance: Double?, currency: String?, modelCount: Int?, updatedAt: Date) {
        self.balance = balance
        self.currency = currency
        self.modelCount = modelCount
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let loginMethod: String
        if let balance, let currency, currency.lowercased() == "usd" {
            let formatted = UsageFormatter.usdString(balance)
            loginMethod = "Balance: \(formatted)"
        } else if let balance {
            let formatted = String(format: "%.2f", balance)
            if let currency {
                loginMethod = "Balance: \(formatted) \(currency.uppercased())"
            } else {
                loginMethod = "Balance: \(formatted)"
            }
        } else if let count = modelCount {
            loginMethod = "API key valid · \(count) models available"
        } else {
            loginMethod = "API key valid"
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum MuseUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Muse API key. Set MUSE_API_KEY or META_API_KEY."
        case let .networkError(message):
            "Muse network error: \(message)"
        case let .apiError(message):
            "Muse API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Muse response: \(message)"
        }
    }
}

public struct MuseUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.muse, scope: "usage"))
    private static let timeoutSeconds: TimeInterval = 15
    public static let defaultBaseURL = "https://api.meta.ai"

    private static func validatedBaseURL(_ base: String) throws -> String {
        // Use the shared validator so embedded user info, encoded delimiters, missing hosts, etc. are rejected
        guard let url = ProviderEndpointOverrideValidator().validatedURLAllowingLoopbackHTTP(base) else {
            throw MuseUsageError.apiError("Insecure base URL — use https:// (or http://localhost for local proxy)")
        }
        let absolute = url.absoluteString
        return absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
    }

    public static func fetchUsage(
        apiKey: String,
        baseURLString: String? = nil,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MuseUsageSnapshot
    {
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MuseUsageError.missingCredentials
        }

        let base = (baseURLString?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? self.defaultBaseURL
        let normalizedBaseRaw = base.hasSuffix("/") ? String(base.dropLast()) : base
        let normalizedBase = try validatedBaseURL(normalizedBaseRaw)

        // Strategy: try balance endpoint first, fall back to models probe.
        // Meta Model API docs list /v1/models and /v1/chat/completions reliably; billing endpoint
        // may evolve (some providers expose /v1/billing/usage or /v1/me/balance).
        // We probe in order and return the first successful snapshot.
        var lastError: Error?

        // 1) Try known billing endpoints (best-effort)
        let billingPaths = [
            "/v1/billing/usage",
            "/v1/me/balance",
            "/v1/billing/subscription",
            "/v1/credits",
        ]
        for path in billingPaths {
            do {
                if let snapshot = try await fetchBalance(
                    base: normalizedBase, path: path, apiKey: cleaned, transport: transport)
                {
                    return snapshot
                }
            } catch {
                lastError = error
                // 401/403 means key invalid — surface immediately
                if let museError = error as? MuseUsageError, case let .apiError(msg) = museError,
                   msg.contains("401") || msg.contains("403")
                {
                    throw error
                }
                continue
            }
        }

        // 2) Fall back to models probe — proves key validity without billing detail
        do {
            return try await self.fetchModelsProbe(base: normalizedBase, apiKey: cleaned, transport: transport)
        } catch let modelsError {
            // Preserve authoritative auth errors from the models probe (401/403 means invalid key)
            if let museError = modelsError as? MuseUsageError, case let .apiError(msg) = museError,
               msg.contains("401") || msg.contains("403")
            {
                throw modelsError
            }
            if let last = lastError { throw last }
            throw modelsError
        }
    }

    private static func fetchBalance(
        base: String,
        path: String,
        apiKey: String,
        transport: any ProviderHTTPTransport) async throws -> MuseUsageSnapshot?
    {
        guard let url = URL(string: "\(base)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await transport.response(for: request)

        // 404 = endpoint not supported — try next
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            self.log.error("Muse balance \(path) returned HTTP \(response.statusCode)")
            throw MuseUsageError.apiError("HTTP \(response.statusCode) at \(path)")
        }

        // Try to parse generic balance shapes
        let summary = try parseBalanceResponse(data: response.data)
        return MuseUsageSnapshot(summary: summary)
    }

    private static func fetchModelsProbe(
        base: String, apiKey: String, transport: any ProviderHTTPTransport) async throws -> MuseUsageSnapshot
    {
        // Support both api.meta.ai and llm.meta.com style hosts
        let paths = ["/v1/models", "/v1/models/list"]
        var lastStatus = 0
        for path in paths {
            guard let url = URL(string: "\(base)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = self.timeoutSeconds

            let response = try await transport.response(for: request)
            lastStatus = response.statusCode
            if (200..<300).contains(response.statusCode) {
                let count = try parseModelsCount(data: response.data)
                let summary = MuseUsageSummary(balance: nil, currency: nil, modelCount: count, updatedAt: Date())
                return MuseUsageSnapshot(summary: summary)
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MuseUsageError.apiError("HTTP \(response.statusCode) — invalid API key")
            }
            if response.statusCode == 404 { continue }
            self.log.error("Muse models probe returned HTTP \(response.statusCode)")
            throw MuseUsageError.apiError("HTTP \(response.statusCode)")
        }
        throw MuseUsageError.apiError("HTTP \(lastStatus) — unable to validate Muse API key")
    }

    static func parseBalanceResponse(data: Data) throws -> MuseUsageSummary {
        // Try multiple JSON shapes:
        // - { available_balance, voucher_balance, cash_balance }
        // - { balance, currency }
        // - { data: { balance, available_balance, currency } }
        // - OpenAI-style { total_available, currency }
        struct Generic: Decodable {
            let available_balance: Double?
            let availableBalance: Double?
            let balance: Double?
            let total_balance: String?
            let totalBalance: String?
            let currency: String?
            let data: GenericData?
        }
        struct GenericData: Decodable {
            let available_balance: Double?
            let balance: Double?
            let total_balance: String?
            let currency: String?
        }

        let decoder = JSONDecoder()
        if let g = try? decoder.decode(Generic.self, from: data) {
            var bal: Double?
            var cur: String?
            bal = g.available_balance
                ?? g.availableBalance
                ?? g.balance
                ?? g.total_balance.flatMap(Double.init)
                ?? g.totalBalance.flatMap(Double.init)
            if bal == nil, let d = g.data {
                bal = d.available_balance
                    ?? d.balance
                    ?? d.total_balance.flatMap(Double.init)
                cur = d.currency
            }
            cur = cur ?? g.currency
            if bal != nil {
                return MuseUsageSummary(balance: bal, currency: cur, modelCount: nil, updatedAt: Date())
            }
        }

        // Fallback: raw dictionary scan
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func scan(_ dict: [String: Any]) -> (Double?, String?) {
                for (k, v) in dict {
                    let lk = k.lowercased()
                    if lk.contains("balance") || lk.contains("credit"), v is Double || v is Int || v is String {
                        let d: Double? = (v as? Double)
                            ?? (v as? Int).map(Double.init)
                            ?? (v as? String).flatMap(Double.init)
                        if let d { return (d, dict["currency"] as? String) }
                    }
                    if let nested = v as? [String: Any] {
                        let r = scan(nested)
                        if r.0 != nil { return r }
                    }
                }
                return (nil, nil)
            }
            let (b, c) = scan(obj)
            if b != nil {
                return MuseUsageSummary(balance: b, currency: c, modelCount: nil, updatedAt: Date())
            }
        }

        throw MuseUsageError.parseFailed("Unknown balance JSON shape")
    }

    static func parseModelsCount(data: Data) throws -> Int? {
        struct ModelsResponse: Decodable {
            let data: [ModelEntry]?
            let models: [ModelEntry]?
        }
        struct ModelEntry: Decodable {
            let id: String?
            let name: String?
        }
        // Require explicit data/models array — {} with no array is malformed and must not be treated as valid auth
        let dec = JSONDecoder()
        if let r = try? dec.decode(ModelsResponse.self, from: data) {
            if let c = r.data?.count ?? r.models?.count {
                return c
            }
            // Both arrays absent → malformed payload, not a valid models list
            throw MuseUsageError.parseFailed("Models response missing data/models array")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = obj["data"] as? [Any] { return arr.count }
            if let arr = obj["models"] as? [Any] { return arr.count }
            // No recognizable array → malformed
            throw MuseUsageError.parseFailed("Models response missing data/models array")
        }
        throw MuseUsageError.parseFailed("Invalid models JSON")
    }

    public static func resolveBaseURL(string: String?) -> URL {
        let base = (string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? self
            .defaultBaseURL
        let normalized = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(normalized)/v1/models")!
    }
}
