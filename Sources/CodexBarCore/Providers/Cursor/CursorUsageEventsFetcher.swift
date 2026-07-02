import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)

// MARK: - Cursor Usage Event Models

/// One page of `POST /api/dashboard/get-filtered-usage-events`.
///
/// `totalUsageEventsCount` reports the total number of events matching the query
/// so pagination can stop once every page has been collected.
struct CursorUsageEventsPage: Decodable, Sendable {
    let totalUsageEventsCount: Int?
    let usageEventsDisplay: [CursorUsageEvent]

    private enum CodingKeys: String, CodingKey {
        case totalUsageEventsCount
        case usageEventsDisplay
    }

    init(totalUsageEventsCount: Int?, usageEventsDisplay: [CursorUsageEvent]) {
        self.totalUsageEventsCount = totalUsageEventsCount
        self.usageEventsDisplay = usageEventsDisplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.totalUsageEventsCount = CursorEventNumber.int64(container, .totalUsageEventsCount).map { Int($0) }
        self.usageEventsDisplay =
            (try? container.decode([CursorUsageEvent].self, forKey: .usageEventsDisplay)) ?? []
    }
}

/// A single account usage event as returned by the Cursor dashboard API.
struct CursorUsageEvent: Decodable, Sendable {
    /// Event time in Unix milliseconds (the API serializes this as a string).
    let timestampMS: Int64?
    let model: String?
    let tokenUsage: CursorEventTokenUsage?
    /// What the plan actually deducts, in cents. Distinct from the notional token cost.
    let chargedCents: Double?

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case model
        case tokenUsage
        case chargedCents
    }

    init(timestampMS: Int64?, model: String?, tokenUsage: CursorEventTokenUsage?, chargedCents: Double? = nil) {
        self.timestampMS = timestampMS
        self.model = model
        self.tokenUsage = tokenUsage
        self.chargedCents = chargedCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestampMS = CursorEventNumber.int64(container, .timestamp)
        self.model = (try? container.decode(String.self, forKey: .model)).flatMap { $0.isEmpty ? nil : $0 }
        self.tokenUsage = try? container.decode(CursorEventTokenUsage.self, forKey: .tokenUsage)
        self.chargedCents = CursorEventNumber.double(container, .chargedCents)
    }
}

/// Token counts and the authoritative token-cost carried by each usage event.
///
/// `totalCents` matches public vendor list pricing, so it is used directly as the
/// cost (converted to USD). Token counts mirror ccusage's mapping, with
/// `cacheWriteTokens` treated as cache-creation input.
struct CursorEventTokenUsage: Decodable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let totalCents: Double?

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheWriteTokens
        case cacheReadTokens
        case totalCents
    }

    init(inputTokens: Int, outputTokens: Int, cacheWriteTokens: Int, cacheReadTokens: Int, totalCents: Double?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalCents = totalCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = CursorEventNumber.int(container, .inputTokens)
        self.outputTokens = CursorEventNumber.int(container, .outputTokens)
        self.cacheWriteTokens = CursorEventNumber.int(container, .cacheWriteTokens)
        self.cacheReadTokens = CursorEventNumber.int(container, .cacheReadTokens)
        self.totalCents = CursorEventNumber.double(container, .totalCents)
    }

    var totalTokens: Int {
        self.inputTokens + self.outputTokens + self.cacheWriteTokens + self.cacheReadTokens
    }

    var hasTokens: Bool {
        self.totalTokens > 0
    }
}

/// Result of fetching Cursor usage for a window.
///
/// `daily` carries the API-rate per-day, per-model breakdown (vendor list price from
/// `tokenUsage.totalCents`). `meteredCostUSD` is what Cursor's plan actually deducts over the
/// same window (sum of each event's `chargedCents`); it is `nil` when no event reported a
/// metered amount, so callers can tell "zero" apart from "unknown".
struct CursorCostFetchResult: Sendable {
    let daily: CostUsageDailyReport
    let meteredCostUSD: Double?
}

/// Lenient numeric decoding because Cursor serializes some numbers as strings.
private enum CursorEventNumber {
    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value) ?? Int(Double(value) ?? 0)
        }
        return 0
    }

    static func double<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    static func int64<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key) { return Int64(value) }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int64(value) ?? Int64(Double(value) ?? 0)
        }
        return nil
    }
}

// MARK: - Cursor Usage Events Fetcher

/// Fetches Cursor token-cost data from the cookie-authenticated dashboard API.
///
/// The caller supplies a resolved `Cookie` header (see ``CursorStatusProbe``); this
/// type only knows how to page the usage endpoints and shape them into a
/// ``CursorCostFetchResult``. Keeping the network surface separate from session
/// resolution makes the mapping unit-testable with a stubbed transport.
struct CursorUsageEventsFetcher: Sendable {
    let baseURL: URL
    let transport: any ProviderHTTPTransport
    var timeout: TimeInterval
    var pageSize: Int
    /// Hard cap so a paging bug can never loop forever (200 * 1000 = 200k events).
    var maxPages: Int

    init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = 30,
        pageSize: Int = 1000,
        maxPages: Int = 200)
    {
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
        self.pageSize = pageSize
        self.maxPages = maxPages
    }

    /// Fetch usage events for the given window (or all history when both bounds are nil)
    /// and shape them into the API-rate per-day report plus the Cursor-metered window total.
    ///
    /// A single fetch backs both numbers, so they always cover the exact same window.
    func fetchUsage(
        cookieHeader: String,
        since: Date?,
        until: Date?,
        calendar: Calendar = .current,
        logger: ((String) -> Void)? = nil) async throws -> CursorCostFetchResult
    {
        let events = try await self.fetchAllEvents(
            cookieHeader: cookieHeader,
            since: since,
            until: until,
            logger: logger)
        return CursorCostFetchResult(
            daily: Self.makeDailyReport(from: events, calendar: calendar),
            meteredCostUSD: Self.meteredCostUSD(from: events))
    }

    private func fetchAllEvents(
        cookieHeader: String,
        since: Date?,
        until: Date?,
        logger: ((String) -> Void)?) async throws -> [CursorUsageEvent]
    {
        var events: [CursorUsageEvent] = []
        var seen = Set<String>()
        for page in 1...self.maxPages {
            let response = try await self.fetchPage(
                cookieHeader: cookieHeader,
                page: page,
                since: since,
                until: until)
            let pageEvents = response.usageEventsDisplay
            if pageEvents.isEmpty { break }
            for event in pageEvents where seen.insert(Self.dedupKey(event)).inserted {
                events.append(event)
            }
            logger?("[cursor-cost] page \(page): \(pageEvents.count) events (\(events.count) total)")
            if pageEvents.count < self.pageSize { break }
            if let total = response.totalUsageEventsCount, events.count >= total { break }
        }
        return events
    }

    private func fetchPage(
        cookieHeader: String,
        page: Int,
        since: Date?,
        until: Date?) async throws -> CursorUsageEventsPage
    {
        let request = try self.makeRequest(
            path: "/api/dashboard/get-filtered-usage-events",
            cookieHeader: cookieHeader,
            body: FilteredUsageRequest(
                teamId: 0,
                page: page,
                pageSize: self.pageSize,
                startDate: Self.millisString(since),
                endDate: Self.millisString(until)))
        let (data, response) = try await self.transport.data(for: request)
        try Self.validate(response)
        return try JSONDecoder().decode(CursorUsageEventsPage.self, from: data)
    }

    // MARK: Request Building

    private struct FilteredUsageRequest: Encodable {
        let teamId: Int
        let page: Int
        let pageSize: Int
        let startDate: String?
        let endDate: String?
    }

    private func makeRequest(path: String, cookieHeader: String, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        // Cursor enforces CSRF on these POST endpoints: a matching Origin is required.
        request.setValue(self.originHeader, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private var originHeader: String {
        guard let scheme = self.baseURL.scheme, let host = self.baseURL.host else {
            return "https://cursor.com"
        }
        return "\(scheme)://\(host)"
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CursorStatusProbeError.networkError("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CursorStatusProbeError.notLoggedIn
        }
        guard http.statusCode == 200 else {
            throw CursorStatusProbeError.networkError("HTTP \(http.statusCode)")
        }
    }

    private static func millisString(_ date: Date?) -> String? {
        date.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) }
    }

    /// Cursor usage events carry no stable id, so dedupe pages on the natural key
    /// of timestamp, model, and token counts.
    private static func dedupKey(_ event: CursorUsageEvent) -> String {
        let usage = event.tokenUsage
        return [
            String(event.timestampMS ?? 0),
            event.model ?? "",
            String(usage?.inputTokens ?? 0),
            String(usage?.outputTokens ?? 0),
            String(usage?.cacheWriteTokens ?? 0),
            String(usage?.cacheReadTokens ?? 0),
        ].joined(separator: "-")
    }

    // MARK: Mapping

    /// Cursor-metered spend in USD: the sum of each event's `chargedCents` (what the plan
    /// deducts), distinct from the API-rate `tokenUsage.totalCents`. Returns `nil` when no
    /// event carried a `chargedCents` value so callers can tell "zero" apart from "unknown".
    static func meteredCostUSD(from events: [CursorUsageEvent]) -> Double? {
        var totalCents = 0.0
        var sawCharged = false
        for event in events {
            guard let cents = event.chargedCents else { continue }
            totalCents += cents
            sawCharged = true
        }
        return sawCharged ? totalCents / 100.0 : nil
    }

    /// Group usage events into per-day, per-model cost entries.
    ///
    /// Events without token usage (or with all-zero token counts) are skipped, matching
    /// ccusage. `totalCents / 100` is the authoritative cost and `cacheWriteTokens` maps
    /// to cache-creation input.
    static func makeDailyReport(
        from events: [CursorUsageEvent],
        calendar: Calendar = .current) -> CostUsageDailyReport
    {
        var days: [String: [String: ModelAccumulator]] = [:]
        for event in events {
            guard let usage = event.tokenUsage, usage.hasTokens else { continue }
            let date = Date(timeIntervalSince1970: Double(event.timestampMS ?? 0) / 1000.0)
            let dayKey = CostUsageLocalDay.key(from: date, calendar: calendar)
            let model = event.model ?? "unknown"
            var modelsForDay = days[dayKey] ?? [:]
            var accumulator = modelsForDay[model] ?? ModelAccumulator()
            accumulator.add(usage)
            modelsForDay[model] = accumulator
            days[dayKey] = modelsForDay
        }

        let entries = days.keys.sorted().map { dayKey in
            Self.makeEntry(date: dayKey, models: days[dayKey] ?? [:])
        }
        return CostUsageDailyReport(data: entries, summary: Self.makeSummary(from: entries))
    }

    private struct ModelAccumulator {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var costUSD = 0.0
        var requestCount = 0

        mutating func add(_ usage: CursorEventTokenUsage) {
            self.inputTokens += usage.inputTokens
            self.outputTokens += usage.outputTokens
            self.cacheReadTokens += usage.cacheReadTokens
            self.cacheCreationTokens += usage.cacheWriteTokens
            self.costUSD += (usage.totalCents ?? 0) / 100.0
            self.requestCount += 1
        }

        var totalTokens: Int {
            self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheCreationTokens
        }
    }

    private static func makeEntry(date: String, models: [String: ModelAccumulator]) -> CostUsageDailyReport.Entry {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var requestCount = 0
        var costUSD = 0.0
        var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []

        for (model, accumulator) in models {
            inputTokens += accumulator.inputTokens
            outputTokens += accumulator.outputTokens
            cacheReadTokens += accumulator.cacheReadTokens
            cacheCreationTokens += accumulator.cacheCreationTokens
            requestCount += accumulator.requestCount
            costUSD += accumulator.costUSD
            breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: accumulator.costUSD,
                totalTokens: accumulator.totalTokens,
                requestCount: accumulator.requestCount))
        }

        return CostUsageDailyReport.Entry(
            date: date,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            totalTokens: inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens,
            requestCount: requestCount,
            costUSD: costUSD,
            modelsUsed: models.keys.sorted(),
            modelBreakdowns: Self.sortedBreakdowns(breakdowns))
    }

    private static func makeSummary(from entries: [CostUsageDailyReport.Entry]) -> CostUsageDailyReport.Summary {
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0
        var totalTokens = 0
        var totalCost = 0.0
        for entry in entries {
            totalInput += entry.inputTokens ?? 0
            totalOutput += entry.outputTokens ?? 0
            totalCacheRead += entry.cacheReadTokens ?? 0
            totalCacheCreation += entry.cacheCreationTokens ?? 0
            totalTokens += entry.totalTokens ?? 0
            totalCost += entry.costUSD ?? 0
        }
        return CostUsageDailyReport.Summary(
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            cacheCreationTokens: totalCacheCreation,
            totalTokens: totalTokens,
            totalCostUSD: totalCost)
    }

    private static func sortedBreakdowns(
        _ breakdowns: [CostUsageDailyReport.ModelBreakdown]) -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
            return lhs.modelName < rhs.modelName
        }
    }
}

#endif
