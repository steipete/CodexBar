import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Usage through the tRPC procedures behind Mistral Admin's usage page (`/api/local-trpc/usage.*`).
/// Mistral moved the page to these procedures in September 2026; the legacy `/api/billing/v2/usage` endpoint
/// started answering HTTP 500 for valid sessions at the same time.
///
/// Rows report consumed units only (no billed share), so daily cost is list price times consumption: the same
/// figure Mistral shows as "Total cost" on the page, and what plan allowances are consumed against.
enum MistralUsageTRPCFetcher {
    private static let baseURL = URL(string: "https://admin.mistral.ai")!

    struct UsageRow: Decodable, Equatable, Sendable {
        let usageType: String?
        let billingGroup: String?
        let billingMetric: String?
        let billingDisplayName: String?
        let apiZone: String?
        let serviceTier: String?
        let timeBucket: String?
        let value: Int?
    }

    struct UsageResponse: Decodable, Sendable {
        struct Metadata: Decodable, Sendable {
            let hasMore: Bool?
        }

        let groups: [UsageRow]
        let metadata: Metadata?
    }

    struct PricesResponse: Decodable, Sendable {
        struct Price: Decodable, Sendable {
            let eventType: String?
            let billingMetric: String?
            let billingGroup: String?
            let apiZone: String?
            let serviceTier: String?
            let price: Double?
        }

        let currency: String?
        let prices: [Price]
    }

    struct Session: Sendable {
        let cookieHeader: String
        let csrfToken: String?
    }

    static func fetchUsage(
        session: Session,
        now: Date,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport) async throws -> MistralUsageSnapshot
    {
        let range = Self.monthRange(containing: now)
        let workspaceID = try await Self.fetchWorkspaceID(session: session, timeout: timeout, transport: transport)
        let prices: PricesResponse = try await Self.call(
            "usage.prices",
            input: ["workspaceId": .string(workspaceID)],
            session: session,
            timeout: timeout,
            transport: transport)
        let usage: UsageResponse = try await Self.call(
            "usage.costTimeseries",
            input: [
                "start": .date(range.start),
                "end": .date(range.end),
                "granularity": .string("day"),
            ],
            session: session,
            timeout: timeout,
            transport: transport)
        guard usage.metadata?.hasMore != true else {
            throw MistralUsageError.parseFailed("Usage rows are paginated; refusing a partial month")
        }
        // Display names are cosmetic: keep the metric name when the breakdown request fails.
        let names: UsageResponse?
        do {
            names = try await Self.call(
                "usage.breakdownByModel",
                input: ["start": .date(range.start), "end": .date(range.end), "chartMetric": .string("tokens")],
                session: session,
                timeout: timeout,
                transport: transport)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            names = nil
        }
        return try Self.makeSnapshot(
            usage: usage,
            prices: prices,
            displayNames: Self.displayNames(from: names),
            range: range,
            updatedAt: now)
    }

    // MARK: - Aggregation

    static func makeSnapshot(
        usage: UsageResponse,
        prices: PricesResponse,
        displayNames: [String: String],
        range: (start: Date, end: Date),
        updatedAt: Date) throws -> MistralUsageSnapshot
    {
        let index = Self.priceIndex(from: prices)
        let rawCurrency = prices.currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let currency = rawCurrency.isEmpty ? "XXX" : rawCurrency
        let currencySymbol = switch currency {
        case "EUR": "€"
        case "USD": "$"
        case "XXX": "¤"
        default: currency
        }

        var entries: [MistralUsageAggregator.Entry] = []
        entries.reserveCapacity(usage.groups.count)
        for row in usage.groups {
            guard let metric = row.billingMetric?.trimmingCharacters(in: .whitespacesAndNewlines), !metric.isEmpty,
                  let group = row.billingGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty,
                  let day = MistralUsageAggregator.dayKey(from: row.timeBucket)
            else { continue }
            let lookup = MistralPriceIndex.Lookup(
                billingMetric: metric,
                billingGroup: group,
                eventType: nil,
                apiZone: row.apiZone,
                serviceTier: row.serviceTier)
            // Token lanes count unless the price table says the row is billed as something else (audio seconds,
            // pages). An unpriced model (new release, table lag) still contributes its tokens at zero cost.
            let eventType = index.resolvedEventType(for: lookup)
            let countsTokens = MistralPriceIndex.tokenBillingGroups.contains(group)
                && (eventType == nil || eventType == MistralPriceIndex.tokenEventType)
            let units = row.value ?? 0
            let cost = Double(units) * (index.price(for: lookup) ?? 0)
            let name = row.billingDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelKey = Self.modelKey(metric: metric, usageType: row.usageType)
            entries.append(MistralUsageAggregator.Entry(
                day: day,
                modelName: (name?.isEmpty == false ? name : nil) ?? displayNames[modelKey] ?? metric,
                modelKey: modelKey,
                lane: MistralUsageAggregator.Lane(billingGroup: group),
                units: units,
                cost: cost.isFinite ? cost : 0,
                tokenScope: countsTokens ? .all : .none))
        }
        return try MistralUsageAggregator.snapshot(entries: entries, period: MistralUsageAggregator.Period(
            costBasis: .consumption,
            currency: currency,
            currencySymbol: currencySymbol,
            startDate: range.start,
            endDate: range.end,
            updatedAt: updatedAt))
    }

    static func priceIndex(from response: PricesResponse) -> MistralPriceIndex {
        var index = MistralPriceIndex()
        for price in response.prices {
            guard let metric = price.billingMetric, let group = price.billingGroup,
                  let value = price.price, value.isFinite
            else { continue }
            index.add(
                billingMetric: metric,
                billingGroup: group,
                row: MistralPriceIndex.Row(
                    eventType: price.eventType,
                    apiZone: price.apiZone,
                    serviceTier: price.serviceTier,
                    price: value))
        }
        return index
    }

    /// The same billing metric is one model under API usage ("mistral-medium-latest") and another under Vibe
    /// Code ("mistral-vibe-cli-latest"), so names and model identity are keyed by metric and usage type.
    static func displayNames(from response: UsageResponse?) -> [String: String] {
        var names: [String: String] = [:]
        for row in response?.groups ?? [] {
            guard let metric = row.billingMetric,
                  let name = row.billingDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { continue }
            let key = Self.modelKey(metric: metric, usageType: row.usageType)
            if names[key] == nil { names[key] = name }
        }
        return names
    }

    static func modelKey(metric: String, usageType: String?) -> String {
        "\(metric)::\(usageType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")"
    }

    static func monthRange(containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? date
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        let end = nextMonth.addingTimeInterval(-0.001)
        return (start, end)
    }

    // MARK: - Transport

    enum InputValue: Sendable {
        case string(String)
        case date(Date)
    }

    private static func fetchWorkspaceID(
        session: Session,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport) async throws -> String
    {
        struct UserResponse: Decodable {
            struct Workspace: Decodable {
                let uuid: String?
            }

            let workspace: Workspace?
        }
        var request = URLRequest(url: self.baseURL.appendingPathComponent("/api/users/me"), timeoutInterval: timeout)
        Self.apply(session: session, to: &request)
        let response = try await transport.response(for: request)
        try MistralUsageFetcher.validate(statusCode: response.statusCode, data: response.data)
        let user: UserResponse
        do {
            user = try JSONDecoder().decode(UserResponse.self, from: response.data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
        guard let workspaceID = user.workspace?.uuid?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceID.isEmpty
        else {
            throw MistralUsageError.parseFailed("Mistral user has no default workspace")
        }
        return workspaceID
    }

    static func call<T: Decodable>(
        _ procedure: String,
        input: [String: InputValue],
        session: Session,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport) async throws -> T
    {
        let url = try Self.url(procedure: procedure, input: input)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        Self.apply(session: session, to: &request)
        let response = try await transport.response(for: request)
        return try Self.decode(T.self, statusCode: response.statusCode, data: response.data)
    }

    static func url(procedure: String, input: [String: InputValue]) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var json: [String: Any] = [:]
        var dateKeys: [String: [String]] = [:]
        for (key, value) in input {
            switch value {
            case let .string(string): json[key] = string
            case let .date(date):
                json[key] = formatter.string(from: date)
                dateKeys[key] = ["Date"]
            }
        }
        var envelope: [String: Any] = ["json": json]
        if !dateKeys.isEmpty {
            envelope["meta"] = ["values": dateKeys]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["0": envelope], options: [.sortedKeys])
        guard let encoded = String(data: payload, encoding: .utf8),
              var components = URLComponents(
                  url: self.baseURL.appendingPathComponent("/api/local-trpc/\(procedure)"),
                  resolvingAgainstBaseURL: false)
        else {
            throw MistralUsageError.apiError("Failed to construct URL")
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: encoded),
        ]
        guard let url = components.url else {
            throw MistralUsageError.apiError("Failed to construct URL")
        }
        return url
    }

    /// tRPC batch envelope: `[{"result":{"data":{"json":…}}}]`, or `[{"error":{"json":{"message":…}}}]` on 4xx.
    private struct Envelope<Payload: Decodable>: Decodable {
        struct Result: Decodable {
            struct Data: Decodable {
                let json: Payload
            }

            let data: Data
        }

        struct Failure: Decodable {
            struct Body: Decodable {
                let message: String?
            }

            let json: Body?
        }

        let result: Result?
        let error: Failure?
    }

    static func decode<T: Decodable>(_: T.Type, statusCode: Int, data: Data) throws -> T {
        if statusCode != 200 {
            // Session failures come first: a 401/403 wrapped in a tRPC error envelope must still let the
            // provider try the next browser session.
            guard !MistralUsageFetcher.isSessionFailure(statusCode: statusCode) else {
                throw MistralUsageError.invalidCredentials
            }
            if let envelope = try? JSONDecoder().decode([Envelope<T>].self, from: data),
               let message = envelope.first?.error?.json?.message
            {
                throw MistralUsageError.apiError("HTTP \(statusCode): \(message.prefix(200))")
            }
            try MistralUsageFetcher.validate(statusCode: statusCode, data: data)
        }
        let envelope: [Envelope<T>]
        do {
            envelope = try JSONDecoder().decode([Envelope<T>].self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }
        if let message = envelope.first?.error?.json?.message {
            throw MistralUsageError.apiError(String(message.prefix(200)))
        }
        guard let payload = envelope.first?.result?.data.json else {
            throw MistralUsageError.parseFailed("Empty tRPC response")
        }
        return payload
    }

    private static func apply(session: Session, to request: inout URLRequest) {
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrfToken = session.csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFTOKEN")
        }
    }
}
