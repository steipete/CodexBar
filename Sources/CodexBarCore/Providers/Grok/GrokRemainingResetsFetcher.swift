import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One unused SuperGrok usage-limit reset token from grok.com.
public struct GrokRemainingReset: Sendable, Equatable {
    public let tokenID: String
    public let grantedAt: Date?
    public let expiresAt: Date

    public init(tokenID: String, grantedAt: Date?, expiresAt: Date) {
        self.tokenID = tokenID
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
    }
}

/// Display-safe reset-credit inventory. Redemption token identifiers stay inside the
/// short-lived fetch cache and never enter a UsageSnapshot or its persisted JSON.
public struct GrokRateLimitResetCreditsSnapshot: Sendable, Equatable {
    static let detailLabel = "Limit Reset Credits"

    public let expirations: [Date]
    public let updatedAt: Date

    public init(expirations: [Date], updatedAt: Date) {
        self.expirations = expirations
            .filter { $0 > updatedAt }
            .sorted()
        self.updatedAt = updatedAt
    }

    public func availableExpirations(at date: Date) -> [Date] {
        self.expirations.filter { $0 > date }.sorted()
    }
}

typealias GrokRemainingResetsLookup = @Sendable (
    _ credentials: GrokCredentials?,
    _ cookieHeader: String?,
    _ now: Date) -> GrokRemainingResetsLookupResult

struct GrokRemainingResetsLookupResult: Sendable {
    let tokens: [GrokRemainingReset]
    let snapshotTask: Task<GrokRateLimitResetCreditsSnapshot?, Never>?

    static let empty = GrokRemainingResetsLookupResult(tokens: [], snapshotTask: nil)

    var supplementalUsageTask: Task<ProviderSupplementalUsageUpdate, Never>? {
        guard let snapshotTask else { return nil }
        return Task {
            await .grokResetCredits(snapshotTask.value)
        }
    }

    func resolved(
        at now: Date,
        requiresCompleteness: Bool) async -> GrokRemainingResetsResolution
    {
        if requiresCompleteness, let snapshotTask {
            return await GrokRemainingResetsResolution(
                snapshot: snapshotTask.value,
                supplementalUsageTask: nil)
        }
        return GrokRemainingResetsResolution(
            snapshot: GrokRemainingResetsFetcher.snapshot(tokens: self.tokens, now: now),
            supplementalUsageTask: self.supplementalUsageTask)
    }
}

struct GrokRemainingResetsResolution: Sendable {
    let snapshot: GrokRateLimitResetCreditsSnapshot?
    let supplementalUsageTask: Task<ProviderSupplementalUsageUpdate, Never>?
}

private final class GrokRemainingResetsCache: @unchecked Sendable {
    private struct Entry {
        var tokens: [GrokRemainingReset]
        var lastAttemptAt: Date?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<GrokRateLimitResetCreditsSnapshot?, Never>] = [:]

    func lookup(
        key: String,
        now: Date,
        refreshInterval: TimeInterval,
        startRefresh: @Sendable ([GrokRemainingReset]) -> Task<GrokRateLimitResetCreditsSnapshot?, Never>) -> (
        tokens: [GrokRemainingReset],
        snapshotTask: Task<GrokRateLimitResetCreditsSnapshot?, Never>?)
    {
        self.lock.lock()
        defer { self.lock.unlock() }

        let entry = self.entries[key] ?? Entry(tokens: [], lastAttemptAt: nil)
        if let task = self.inFlight[key] {
            return (entry.tokens, task)
        }
        let isFresh = entry.lastAttemptAt.map { now.timeIntervalSince($0) < refreshInterval } ?? false
        guard !isFresh else {
            return (entry.tokens, nil)
        }
        let task = startRefresh(entry.tokens)
        self.inFlight[key] = task
        return (entry.tokens, task)
    }

    func finishRefresh(key: String, tokens: [GrokRemainingReset]?, attemptedAt: Date) {
        self.lock.lock()
        defer { self.lock.unlock() }

        let retained = self.entries[key]?.tokens ?? []
        self.entries[key] = Entry(tokens: tokens ?? retained, lastAttemptAt: attemptedAt)
        self.inFlight.removeValue(forKey: key)
    }

    func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeAll()
        self.inFlight.removeAll()
    }
}

/// SuperGrok usage-limit reset coupons live on grok.com's consumer billing RPC, not on the
/// CLI-proxy credits payload. A successful weekly-usage refresh must not fail just because
/// this extra inventory call times out or returns an empty set.
enum GrokRemainingResetsFetcher {
    static let defaultEndpoint = URL(
        string: "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets")!
    static let requestTimeoutSeconds: TimeInterval = 2
    static let joinGrace = Duration.seconds(2)
    static let cacheRefreshInterval: TimeInterval = 60
    private static let cache = GrokRemainingResetsCache()

    typealias Refresh = @Sendable (
        _ credentials: GrokCredentials?,
        _ cookieHeader: String?,
        _ now: Date) async -> [GrokRemainingReset]?

    /// Returns cached inventory immediately and refreshes it in the background. The optional
    /// coupon endpoint must never hold back an already-completed weekly-usage result.
    static func cachedTokensAndRefresh(
        credentials: GrokCredentials?,
        cookieHeader: String?,
        now: Date = .init()) -> [GrokRemainingReset]
    {
        self.cachedLookupAndRefresh(
            credentials: credentials,
            cookieHeader: cookieHeader,
            now: now,
            refresh: { credentials, cookieHeader, now in
                await Self.fetchResult(
                    credentials: credentials,
                    cookieHeader: cookieHeader,
                    now: now)
            }).tokens
    }

    static func cachedTokensAndRefresh(
        credentials: GrokCredentials?,
        cookieHeader: String?,
        now: Date,
        refresh: @escaping Refresh) -> [GrokRemainingReset]
    {
        self.cachedLookupAndRefresh(
            credentials: credentials,
            cookieHeader: cookieHeader,
            now: now,
            refresh: refresh).tokens
    }

    static func cachedLookupAndRefresh(
        credentials: GrokCredentials?,
        cookieHeader: String?,
        now: Date = .init()) -> GrokRemainingResetsLookupResult
    {
        self.cachedLookupAndRefresh(
            credentials: credentials,
            cookieHeader: cookieHeader,
            now: now,
            refresh: { credentials, cookieHeader, now in
                await Self.fetchResult(
                    credentials: credentials,
                    cookieHeader: cookieHeader,
                    now: now)
            })
    }

    static func cachedLookupAndRefresh(
        credentials: GrokCredentials?,
        cookieHeader: String?,
        now: Date,
        refresh: @escaping Refresh) -> GrokRemainingResetsLookupResult
    {
        guard let key = cacheKey(credentials: credentials, cookieHeader: cookieHeader) else {
            return .empty
        }
        let state = Self.cache.lookup(
            key: key,
            now: now,
            refreshInterval: Self.cacheRefreshInterval,
            startRefresh: { retainedTokens in
                Task {
                    let tokens = await refresh(credentials, cookieHeader, now)
                    Self.cache.finishRefresh(key: key, tokens: tokens, attemptedAt: now)
                    return Self.snapshot(tokens: tokens ?? retainedTokens, now: now)
                }
            })
        return GrokRemainingResetsLookupResult(tokens: state.tokens, snapshotTask: state.snapshotTask)
    }

    static func resetCacheForTesting() {
        self.cache.reset()
    }

    static func fetch(
        credentials: GrokCredentials?,
        cookieHeader: String?,
        now: Date = .init(),
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async -> [GrokRemainingReset]
    {
        await self.fetchResult(
            credentials: credentials,
            cookieHeader: cookieHeader,
            now: now,
            session: transport,
            endpoint: endpoint) ?? []
    }

    static func fetchResult(
        credentials: GrokCredentials?,
        cookieHeader: String?,
        now: Date = .init(),
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async -> [GrokRemainingReset]?
    {
        let authorizationHeader = credentials.flatMap { credential in
            credential.isExpired ? nil : "Bearer \(credential.accessToken)"
        }
        guard authorizationHeader != nil || !(cookieHeader?.isEmpty ?? true) else {
            return []
        }

        let sourceTask = Task<[GrokRemainingReset], Error> {
            try await Self.fetchOnce(
                authorizationHeader: authorizationHeader,
                cookieHeader: cookieHeader,
                now: now,
                transport: transport,
                endpoint: endpoint)
        }
        let outcome = await BoundedTaskJoin(sourceTask: sourceTask).value(joinGrace: Self.joinGrace)
        if Task.isCancelled {
            return []
        }
        switch outcome {
        case let .value(tokens):
            return tokens
        case .timedOut, .failure:
            return nil
        }
    }

    private static func cacheKey(credentials: GrokCredentials?, cookieHeader: String?) -> String? {
        var components: [String] = []
        if let credentials, !credentials.isExpired {
            components.append("bearer:\(CookieHeaderCache.credentialFingerprint(credentials.accessToken))")
        }
        if let cookieHeader = GrokCredentialRouting.normalizedWebCookie(cookieHeader) {
            components.append("cookie:\(CookieHeaderCache.credentialFingerprint(cookieHeader))")
        }
        return components.isEmpty ? nil : components.joined(separator: "|")
    }

    static func detailSections(tokens: [GrokRemainingReset], now: Date) -> [ProviderDetailSection] {
        self.detailSections(
            expirations: self.availableTokens(tokens, now: now).map(\.expiresAt),
            now: now)
    }

    static func detailSections(
        snapshot: GrokRateLimitResetCreditsSnapshot?,
        now: Date) -> [ProviderDetailSection]
    {
        self.detailSections(
            expirations: snapshot?.availableExpirations(at: now) ?? [],
            now: now)
    }

    private static func detailSections(expirations: [Date], now: Date) -> [ProviderDetailSection] {
        guard let next = expirations.first else { return [] }
        let value = expirations.count == 1 ? "1 available" : "\(expirations.count) available"
        return [
            .makeSection(
                rows: [
                    .makeRow(
                        label: GrokRateLimitResetCreditsSnapshot.detailLabel,
                        value: value,
                        secondaryValue: "Expires \(UsageFormatter.resetDescription(from: next, now: now))"),
                ]),
        ]
    }

    static func snapshot(
        tokens: [GrokRemainingReset],
        now: Date) -> GrokRateLimitResetCreditsSnapshot?
    {
        let available = self.availableTokens(tokens, now: now)
        guard !available.isEmpty else { return nil }
        return GrokRateLimitResetCreditsSnapshot(
            expirations: available.map(\.expiresAt),
            updatedAt: now)
    }

    static func parseTokens(_ data: Data, now: Date = .init()) throws -> [GrokRemainingReset] {
        var payloads = GrokWebBillingFetcher.grpcWebDataFrames(from: data)
        if payloads.isEmpty, GrokWebBillingFetcher.looksLikeProtobufPayload(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { throw GrokWebBillingError.parseFailed }
        try GrokWebBillingFetcher.validateGRPCWebTrailers(data)

        var tokens: [GrokRemainingReset] = []
        for payload in payloads {
            guard !payload.isEmpty else { continue }
            guard let parsed = Self.parseMessage(payload, now: now), parsed.containsTokenRecord else {
                throw GrokWebBillingError.parseFailed
            }
            tokens.append(contentsOf: parsed.tokens)
        }
        return tokens
            .filter { $0.expiresAt > now && !$0.tokenID.isEmpty }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    private static func availableTokens(
        _ tokens: [GrokRemainingReset],
        now: Date) -> [GrokRemainingReset]
    {
        tokens
            .filter { $0.expiresAt > now && !$0.tokenID.isEmpty }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    private static func fetchOnce(
        authorizationHeader: String?,
        cookieHeader: String?,
        now: Date,
        transport: any ProviderHTTPTransport,
        endpoint: URL) async throws -> [GrokRemainingReset]
    {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw GrokWebBillingError.invalidResponse
        }
        guard response.statusCode == 200 else {
            let body = String(data: response.data.prefix(400), encoding: .utf8) ?? ""
            throw GrokWebBillingError.requestFailed(response.statusCode, body)
        }
        try GrokWebBillingFetcher.validateGRPCStatusFields(
            GrokWebBillingFetcher.grpcHeaderFields(from: response.response.allHeaderFields))
        return try Self.parseTokens(response.data, now: now)
    }

    private struct ParsedMessage {
        let tokens: [GrokRemainingReset]
        let containsTokenRecord: Bool
    }

    private struct ParsedToken {
        let token: GrokRemainingReset?
    }

    private static func parseMessage(_ data: Data, now: Date) -> ParsedMessage? {
        let bytes = [UInt8](data)
        var tokens: [GrokRemainingReset] = []
        var containsTokenRecord = false
        var index = 0
        while index < bytes.count {
            guard let key = Self.readVarint(bytes, index: &index), key != 0 else { return nil }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            switch wireType {
            case 0:
                guard Self.readVarint(bytes, index: &index) != nil else { return nil }
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
            case 2:
                guard let length = Self.readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    return nil
                }
                let start = index
                let end = index + Int(length)
                if fieldNumber == 10 {
                    containsTokenRecord = true
                    guard let parsed = Self.parseToken(Data(bytes[start..<end]), now: now) else {
                        return nil
                    }
                    if let token = parsed.token {
                        tokens.append(token)
                    }
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
        return ParsedMessage(tokens: tokens, containsTokenRecord: containsTokenRecord)
    }

    private static func parseToken(_ data: Data, now: Date) -> ParsedToken? {
        let bytes = [UInt8](data)
        var tokenID = ""
        var grantedAt: Date?
        var expiresAt: Date?
        var index = 0
        while index < bytes.count {
            guard let key = Self.readVarint(bytes, index: &index), key != 0 else { return nil }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            switch wireType {
            case 0:
                guard Self.readVarint(bytes, index: &index) != nil else { return nil }
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
            case 2:
                guard let length = Self.readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    return nil
                }
                let start = index
                let end = index + Int(length)
                let payload = Data(bytes[start..<end])
                if fieldNumber == 10 {
                    tokenID = String(data: payload, encoding: .utf8) ?? ""
                } else if fieldNumber == 20 {
                    grantedAt = Self.timestamp(from: payload)
                } else if fieldNumber == 30 {
                    expiresAt = Self.timestamp(from: payload)
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
        guard !tokenID.isEmpty, let expiresAt else { return nil }
        guard expiresAt > now else { return ParsedToken(token: nil) }
        return ParsedToken(token: GrokRemainingReset(
            tokenID: tokenID,
            grantedAt: grantedAt,
            expiresAt: expiresAt))
    }

    private static func timestamp(from data: Data) -> Date? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let fieldStart = index
            guard let key = Self.readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            switch wireType {
            case 0:
                if let value = Self.readVarint(bytes, index: &index),
                   fieldNumber == 1,
                   value >= 1_700_000_000,
                   value <= 2_100_000_000
                {
                    return Date(timeIntervalSince1970: TimeInterval(value))
                }
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
            case 2:
                guard let length = Self.readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    return nil
                }
                index += Int(length)
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
        return nil
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
            if shift > 63 {
                return nil
            }
        }
        return nil
    }
}
