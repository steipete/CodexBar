import Foundation

public enum HuggingFaceUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case missingBillingPermission
    case rateLimited(retryAfterSeconds: Int?)
    case apiError(Int)
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Hugging Face token. Add one in Settings or set HF_TOKEN."
        case .invalidCredentials:
            "Hugging Face rejected the token. Check that it is valid and not expired."
        case .missingBillingPermission:
            "The Hugging Face token lacks billing access. Use a classic read token, or enable the "
                + "Billing read permission on your fine-grained token."
        case let .rateLimited(retryAfterSeconds):
            if let retryAfterSeconds {
                "Hugging Face rate limit reached. Retry in \(retryAfterSeconds)s."
            } else {
                "Hugging Face rate limit reached. Retry later."
            }
        case let .apiError(statusCode):
            "Hugging Face API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Hugging Face billing response format changed: \(message)"
        case let .networkError(message):
            "Hugging Face network error: \(message)"
        }
    }
}

public struct HuggingFaceUsageSnapshot: Sendable, Equatable {
    public struct InferenceCredits: Sendable, Equatable {
        public let usedUSD: Double
        public let includedUSD: Double
        public let limitUSD: Double?
        public let requestCount: Int?
        public let periodEnd: Date?
    }

    public struct ZeroGPUQuota: Sendable, Equatable {
        public let totalSeconds: Double
        public let remainingSeconds: Double
        public let resetsAt: Date?
    }

    public struct Identity: Sendable, Equatable {
        public let username: String?
        public let email: String?
        public let isPro: Bool
    }

    public let credits: InferenceCredits
    public let zeroGPU: ZeroGPUQuota?
    public let identity: Identity?
    public let updatedAt: Date
}

/// Process-lifetime cache for whoami-v2 results. Hugging Face rate-limits that
/// endpoint far more aggressively than the rest of the Hub API, so identity is
/// refreshed at most once per TTL per token.
actor HuggingFaceIdentityCache {
    static let shared = HuggingFaceIdentityCache()

    struct Entry: Sendable {
        let identity: HuggingFaceUsageSnapshot.Identity
        let periodEnd: Date?
        let fetchedAt: Date
    }

    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]

    init(ttl: TimeInterval = 12 * 60 * 60) {
        self.ttl = ttl
    }

    func validEntry(forToken token: String, now: Date) -> Entry? {
        guard let entry = self.entries[token],
              now.timeIntervalSince(entry.fetchedAt) < self.ttl
        else {
            return nil
        }
        return entry
    }

    func store(_ entry: Entry, forToken token: String) {
        self.entries[token] = entry
    }
}

public enum HuggingFaceUsageFetcher {
    private static let baseURL = URL(string: "https://huggingface.co")!
    private static let timeoutSeconds: TimeInterval = 20

    public static func fetchUsage(apiKey: String) async throws -> HuggingFaceUsageSnapshot {
        try await self.fetchUsage(
            apiKey: apiKey,
            transport: ProviderHTTPClient.shared,
            identityCache: .shared,
            now: Date())
    }

    static func _fetchUsageForTesting(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        identityCache: HuggingFaceIdentityCache = HuggingFaceIdentityCache(),
        now: Date = Date()) async throws -> HuggingFaceUsageSnapshot
    {
        try await self.fetchUsage(apiKey: apiKey, transport: transport, identityCache: identityCache, now: now)
    }

    private static func fetchUsage(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        identityCache: HuggingFaceIdentityCache,
        now: Date) async throws -> HuggingFaceUsageSnapshot
    {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HuggingFaceUsageError.missingCredentials }

        do {
            // Required: month-to-date Inference Providers credits.
            let usageResponse = try await transport.response(
                for: self.request(path: "api/settings/billing/usage-v2", token: token, queryItems: [
                    URLQueryItem(
                        name: "startDate",
                        value: String(Int(self.monthStart(for: now).timeIntervalSince1970))),
                    URLQueryItem(name: "endDate", value: String(Int(now.timeIntervalSince1970))),
                ]),
                retryPolicy: .transientIdempotent)
            try self.validate(usageResponse)
            var credits = try self.decodeCredits(usageResponse.data)

            // Best-effort: ZeroGPU quota; failures drop the secondary metric only.
            let zeroGPU = await self.fetchZeroGPU(transport: transport, token: token)

            // Best-effort and cached: identity; failures drop identity only.
            let identityEntry = await self.fetchIdentity(
                transport: transport, token: token, cache: identityCache, now: now)
            if let periodEnd = identityEntry?.periodEnd {
                credits = InferenceCreditsOverride.withPeriodEnd(credits, periodEnd)
            }

            return HuggingFaceUsageSnapshot(
                credits: credits,
                zeroGPU: zeroGPU,
                identity: identityEntry?.identity,
                updatedAt: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HuggingFaceUsageError {
            throw error
        } catch let error as DecodingError {
            throw HuggingFaceUsageError.parseFailed(error.localizedDescription)
        } catch {
            throw HuggingFaceUsageError.networkError(error.localizedDescription)
        }
    }

    private static func decodeCredits(_ data: Data) throws -> HuggingFaceUsageSnapshot.InferenceCredits {
        let response: HuggingFaceUsageV2Response
        do {
            response = try JSONDecoder().decode(HuggingFaceUsageV2Response.self, from: data)
        } catch {
            throw HuggingFaceUsageError.parseFailed(error.localizedDescription)
        }
        guard let inference = response.usage?.inferenceProviders,
              let usedNanoUSD = inference.usedNanoUsd
        else {
            throw HuggingFaceUsageError.parseFailed("missing inferenceProviders usage")
        }
        let limitNanoUSD = inference.limitNanoUsd ?? 0
        return HuggingFaceUsageSnapshot.InferenceCredits(
            usedUSD: usedNanoUSD / 1_000_000_000,
            includedUSD: (inference.includedNanoUsd ?? 0) / 1_000_000_000,
            limitUSD: limitNanoUSD > 0 ? limitNanoUSD / 1_000_000_000 : nil,
            requestCount: inference.numRequests,
            periodEnd: inference.periodEnd?.date)
    }

    private static func fetchZeroGPU(
        transport: any ProviderHTTPTransport,
        token: String) async -> HuggingFaceUsageSnapshot.ZeroGPUQuota?
    {
        guard let response = try? await transport.response(
            for: self.request(path: "api/spaces/zero-gpu/quota", token: token, queryItems: [])),
            (200..<300).contains(response.statusCode),
            let quota = try? JSONDecoder().decode(HuggingFaceZeroGPUQuotaResponse.self, from: response.data),
            let base = quota.base, base > 0,
            let current = quota.current
        else {
            return nil
        }
        return HuggingFaceUsageSnapshot.ZeroGPUQuota(
            totalSeconds: base,
            remainingSeconds: current,
            resetsAt: quota.resetsAt?.date)
    }

    private static func fetchIdentity(
        transport: any ProviderHTTPTransport,
        token: String,
        cache: HuggingFaceIdentityCache,
        now: Date) async -> HuggingFaceIdentityCache.Entry?
    {
        if let cached = await cache.validEntry(forToken: token, now: now) {
            return cached
        }
        guard let response = try? await transport.response(
            for: self.request(path: "api/whoami-v2", token: token, queryItems: [])),
            (200..<300).contains(response.statusCode),
            let whoami = try? JSONDecoder().decode(HuggingFaceWhoAmIResponse.self, from: response.data)
        else {
            return nil
        }
        let entry = HuggingFaceIdentityCache.Entry(
            identity: HuggingFaceUsageSnapshot.Identity(
                username: whoami.name,
                email: whoami.email,
                isPro: whoami.isPro ?? false),
            periodEnd: whoami.periodEnd.map { Date(timeIntervalSince1970: $0) },
            fetchedAt: now)
        await cache.store(entry, forToken: token)
        return entry
    }

    private static func request(path: String, token: String, queryItems: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(
            url: self.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validate(_ response: ProviderHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw HuggingFaceUsageError.invalidCredentials
        case 403:
            throw HuggingFaceUsageError.missingBillingPermission
        case 429:
            throw HuggingFaceUsageError.rateLimited(
                retryAfterSeconds: self.retryAfterSeconds(from: response))
        default:
            throw HuggingFaceUsageError.apiError(response.statusCode)
        }
    }

    /// Parses the IETF draft `RateLimit` header (`"api";r=0;t=33`) or `Retry-After`.
    static func retryAfterSeconds(from response: ProviderHTTPResponse) -> Int? {
        if let policy = response.response.value(forHTTPHeaderField: "RateLimit") {
            for part in policy.split(separator: ";") {
                let token = part.trimmingCharacters(in: .whitespaces)
                if token.hasPrefix("t="), let seconds = Int(token.dropFirst(2)) {
                    return seconds
                }
            }
        }
        if let retryAfter = response.response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int(retryAfter.trimmingCharacters(in: .whitespaces))
        {
            return seconds
        }
        return nil
    }

    private static func monthStart(for now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: now)
        return calendar.date(from: components) ?? now
    }
}

/// Rebuilds `InferenceCredits` with the authoritative whoami billing period end.
private enum InferenceCreditsOverride {
    static func withPeriodEnd(
        _ credits: HuggingFaceUsageSnapshot.InferenceCredits,
        _ periodEnd: Date) -> HuggingFaceUsageSnapshot.InferenceCredits
    {
        HuggingFaceUsageSnapshot.InferenceCredits(
            usedUSD: credits.usedUSD,
            includedUSD: credits.includedUSD,
            limitUSD: credits.limitUSD,
            requestCount: credits.requestCount,
            periodEnd: periodEnd)
    }
}
