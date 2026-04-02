import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MistralFetcher {
    private static let log = CodexBarLog.logger(LogCategories.mistralUsage)
    private static let timeout: TimeInterval = 15
    private static let maxErrorBodyLength = 240

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession? = nil) async throws -> MistralAPIUsageSnapshot
    {
        guard let cleanedKey = MistralSettingsReader.cleaned(apiKey) else {
            throw MistralUsageError.missingToken
        }

        let session = session ?? Self.makeSession()
        let requestURL = self.modelsURL(environment: environment)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralUsageError.invalidResponse
        }

        let responseBody = Self.bodySnippet(from: data, maxLength: Self.maxErrorBodyLength)
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MistralUsageError.unauthorized
            }
            if httpResponse.statusCode == 429 {
                let retryAfter = Self.retryAfterDate(headers: httpResponse.allHeaderFields)
                throw MistralUsageError.rateLimited(retryAfter: retryAfter)
            }
            throw MistralUsageError.unexpectedStatus(code: httpResponse.statusCode, body: responseBody)
        }

        let decoded: MistralModelListResponse
        do {
            decoded = try Self.parseModelListResponse(data: data)
        } catch {
            let snippet = responseBody ?? "<empty>"
            Self.log.error("Failed to decode Mistral model list: \(error.localizedDescription) | body: \(snippet)")
            throw MistralUsageError.decodeFailed("\(error.localizedDescription) | body: \(snippet)")
        }

        let rateLimits = MistralRateLimitSnapshot(
            requests: Self.rateLimitWindow(
                kind: "requests",
                headers: httpResponse.allHeaderFields,
                now: Date()),
            tokens: Self.rateLimitWindow(
                kind: "tokens",
                headers: httpResponse.allHeaderFields,
                now: Date()),
            retryAfter: Self.retryAfterDate(headers: httpResponse.allHeaderFields))

        return MistralAPIUsageSnapshot(
            models: decoded.data,
            rateLimits: rateLimits.orderedWindows.isEmpty ? nil : rateLimits,
            updatedAt: Date())
    }

    public static func fetchBillingUsage(
        cookieHeader: String,
        csrfToken: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval? = nil,
        session: URLSession? = nil) async throws -> MistralBillingUsageSnapshot
    {
        guard let override = MistralCookieHeader.override(
            from: cookieHeader,
            explicitCSRFToken: MistralSettingsReader.cleaned(csrfToken))
        else {
            throw MistralUsageError.invalidCookie
        }

        let requestTimeout = timeout ?? Self.timeout
        let session = session ?? Self.makeSession(timeout: requestTimeout)
        let now = Date()
        var lastError: MistralUsageError?

        for requestURL in self.billingURLs(environment: environment, now: now) {
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.timeoutInterval = requestTimeout
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue(override.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(self.referer(for: requestURL), forHTTPHeaderField: "Referer")
            request.setValue(self.origin(for: requestURL), forHTTPHeaderField: "Origin")
            if let csrf = MistralSettingsReader.cleaned(csrfToken ?? override.csrfToken) {
                request.setValue(csrf, forHTTPHeaderField: "X-CSRFTOKEN")
            }

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = MistralUsageError.networkError(error.localizedDescription)
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MistralUsageError.invalidResponse
            }

            let responseBody = Self.bodySnippet(from: data, maxLength: Self.maxErrorBodyLength)
            switch httpResponse.statusCode {
            case 200:
                do {
                    return try Self.parseBillingResponse(data: data, updatedAt: now)
                } catch let error as MistralUsageError {
                    throw error
                } catch {
                    let snippet = responseBody ?? "<empty>"
                    Self.log.error("Failed to parse Mistral billing response: \(error.localizedDescription) | body: \(snippet)")
                    throw MistralUsageError.parseFailed("\(error.localizedDescription) | body: \(snippet)")
                }
            case 401, 403:
                throw MistralUsageError.invalidCredentials
            case 404:
                lastError = MistralUsageError.unexpectedStatus(code: httpResponse.statusCode, body: responseBody)
                continue
            default:
                throw MistralUsageError.unexpectedStatus(code: httpResponse.statusCode, body: responseBody)
            }
        }

        throw lastError ?? MistralUsageError.missingCookie
    }

    private static func makeSession(timeout: TimeInterval? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout ?? Self.timeout
        configuration.timeoutIntervalForResource = timeout ?? Self.timeout
        return URLSession(configuration: configuration)
    }

    private static func modelsURL(environment: [String: String]) -> URL {
        MistralSettingsReader.apiURL(environment: environment).appendingPathComponent("models")
    }

    private static func billingURLs(environment: [String: String], now: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

        let queryItems = [
            URLQueryItem(name: "month", value: String(calendar.component(.month, from: now))),
            URLQueryItem(name: "year", value: String(calendar.component(.year, from: now))),
            URLQueryItem(name: "by_workspace", value: "true"),
        ]

        let bases = [
            MistralSettingsReader.consoleURL(environment: environment),
            MistralSettingsReader.adminURL(environment: environment),
        ]

        var urls: [URL] = []
        var seen = Set<String>()
        for base in bases {
            let usageURL = base.appendingPathComponent("api/billing/v2/usage")
            var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            let url = components?.url ?? usageURL
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    private static func referer(for requestURL: URL) -> String {
        let host = requestURL.host ?? "console.mistral.ai"
        if host.hasPrefix("console.") {
            return "https://\(host)/usage"
        }
        return "https://\(host)/organization/usage"
    }

    private static func origin(for requestURL: URL) -> String {
        let scheme = requestURL.scheme ?? "https"
        let host = requestURL.host ?? "console.mistral.ai"
        return "\(scheme)://\(host)"
    }

    private static func rateLimitWindow(
        kind: String,
        headers: [AnyHashable: Any],
        now: Date) -> MistralRateLimitWindow?
    {
        let normalized = Self.normalizedHeaders(headers)
        let limit = Self.intValue(
            in: normalized,
            keys: Self.limitKeys(kind: kind))
        let remaining = Self.intValue(
            in: normalized,
            keys: Self.remainingKeys(kind: kind))
        let resetAt = Self.dateValue(
            in: normalized,
            keys: Self.resetKeys(kind: kind),
            now: now)

        guard limit != nil || remaining != nil || resetAt != nil else {
            return nil
        }

        let resetDescription: String? = {
            if let limit, let remaining {
                return "\(Self.capitalized(kind)): \(remaining)/\(limit)"
            }
            if let resetAt {
                return "\(Self.capitalized(kind)) reset \(Self.formatDate(resetAt))"
            }
            if let limit {
                return "\(Self.capitalized(kind)): limit \(limit)"
            }
            if let remaining {
                return "\(Self.capitalized(kind)): \(remaining) remaining"
            }
            return nil
        }()

        return MistralRateLimitWindow(
            kind: kind,
            limit: limit,
            remaining: remaining,
            resetsAt: resetAt,
            resetDescription: resetDescription)
    }

    private static func retryAfterDate(headers: [AnyHashable: Any]) -> Date? {
        let normalized = Self.normalizedHeaders(headers)
        if let date = Self.dateValue(in: normalized, keys: ["retry-after"], now: Date()) {
            return date
        }
        if let seconds = Self.intValue(in: normalized, keys: ["retry-after"]) {
            return Date(timeIntervalSinceNow: TimeInterval(seconds))
        }
        return nil
    }

    private static func normalizedHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (key, value) in headers {
            let keyString = String(describing: key).lowercased()
            let valueString = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            normalized[keyString] = valueString
        }
        return normalized
    }

    private static func intValue(in headers: [String: String], keys: [String]) -> Int? {
        for key in keys {
            guard let value = headers[key] else { continue }
            if let int = Int(value) {
                return int
            }
            if let double = Double(value) {
                return Int(double.rounded())
            }
        }
        return nil
    }

    private static func dateValue(in headers: [String: String], keys: [String], now: Date) -> Date? {
        for key in keys {
            guard let raw = headers[key], !raw.isEmpty else { continue }
            if let seconds = Int(raw) {
                return Self.interpretTimestamp(seconds, now: now)
            }
            if let double = Double(raw) {
                return Self.interpretTimestamp(double, now: now)
            }
            if let iso = Self.makeISO8601DateFormatter().date(from: raw) {
                return iso
            }
            if let rfc = Self.makeRFC1123DateFormatter().date(from: raw) {
                return rfc
            }
            if let reset = Self.makeHTTPDateFormatter().date(from: raw) {
                return reset
            }
        }
        return nil
    }

    private static func limitKeys(kind: String) -> [String] {
        [
            "x-ratelimit-limit-\(kind)",
            "ratelimit-limit-\(kind)",
            "x-rate-limit-limit-\(kind)",
            "x-ratelimit-limit",
            "ratelimit-limit",
        ]
    }

    private static func remainingKeys(kind: String) -> [String] {
        [
            "x-ratelimit-remaining-\(kind)",
            "ratelimit-remaining-\(kind)",
            "x-rate-limit-remaining-\(kind)",
            "x-ratelimit-remaining",
            "ratelimit-remaining",
        ]
    }

    private static func resetKeys(kind: String) -> [String] {
        [
            "x-ratelimit-reset-\(kind)",
            "ratelimit-reset-\(kind)",
            "x-rate-limit-reset-\(kind)",
            "x-ratelimit-reset",
            "ratelimit-reset",
        ]
    }

    private static func interpretTimestamp(_ value: Int, now: Date) -> Date {
        if value >= 1_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return now.addingTimeInterval(TimeInterval(value))
    }

    private static func interpretTimestamp(_ value: Double, now: Date) -> Date {
        if value >= 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return now.addingTimeInterval(value)
    }

    private static func bodySnippet(from data: Data, maxLength: Int) -> String? {
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maxLength))
    }

    static func parseModelListResponse(data: Data) throws -> MistralModelListResponse {
        let json = try JSONSerialization.jsonObject(with: data)

        if let object = json as? [String: Any] {
            let listObject = object["object"] as? String
            let items = object["data"] as? [[String: Any]] ?? []
            return MistralModelListResponse(
                object: listObject,
                data: items.map(Self.parseModelCard))
        }

        if let items = json as? [[String: Any]] {
            return MistralModelListResponse(
                object: "list",
                data: items.map(Self.parseModelCard))
        }

        throw MistralUsageError.decodeFailed("Unexpected top-level response shape")
    }

    static func parseBillingResponse(data: Data, updatedAt: Date) throws -> MistralBillingUsageSnapshot {
        let json = try JSONSerialization.jsonObject(with: data)
        let root = json as? [String: Any]
        let decoder = JSONDecoder()
        let billing: MistralBillingResponse
        do {
            billing = try decoder.decode(MistralBillingResponse.self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }

        let prices = Self.buildPriceIndex(billing.prices ?? [])
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCachedTokens = 0
        var totalCost = 0.0
        var modelNames: Set<String> = []

        for category in Self.categoryModelMaps(from: billing) {
            for (modelKey, usageData) in category {
                let modelTotals = Self.aggregateModelUsage(usageData, prices: prices)
                totalInputTokens += modelTotals.input
                totalOutputTokens += modelTotals.output
                totalCachedTokens += modelTotals.cached
                totalCost += modelTotals.cost

                let displayName = Self.displayName(for: modelKey, usageData: usageData)
                if !displayName.isEmpty {
                    modelNames.insert(displayName)
                }
            }
        }

        let workspaces = self.parseWorkspaceSnapshots(root: root, prices: prices)

        return MistralBillingUsageSnapshot(
            totalCost: totalCost,
            currency: billing.currency ?? "EUR",
            currencySymbol: billing.currencySymbol ?? billing.currency ?? "EUR",
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCachedTokens: totalCachedTokens,
            modelCount: modelNames.count,
            startDate: billing.startDate.flatMap(Self.date(fromBillingString:)),
            endDate: billing.endDate.flatMap(Self.date(fromBillingString:)),
            workspaces: workspaces,
            updatedAt: updatedAt)
    }

    private static func parseModelCard(_ object: [String: Any]) -> MistralModelCard {
        let capabilitiesObject = object["capabilities"] as? [String: Any] ?? [:]
        return MistralModelCard(
            id: Self.string(object["id"]) ?? "unknown-model",
            object: Self.string(object["object"]),
            created: Self.int(object["created"]),
            ownedBy: Self.string(object["owned_by"]),
            capabilities: MistralModelCapabilities(
                completionChat: Self.bool(capabilitiesObject["completion_chat"]),
                completionFim: Self.bool(capabilitiesObject["completion_fim"]),
                functionCalling: Self.bool(capabilitiesObject["function_calling"]),
                fineTuning: Self.bool(capabilitiesObject["fine_tuning"]),
                vision: Self.bool(capabilitiesObject["vision"]),
                ocr: Self.bool(capabilitiesObject["ocr"]),
                classification: Self.bool(capabilitiesObject["classification"]),
                moderation: Self.bool(capabilitiesObject["moderation"]),
                audio: Self.bool(capabilitiesObject["audio"]),
                audioTranscription: Self.bool(capabilitiesObject["audio_transcription"])),
            name: Self.string(object["name"]),
            description: Self.string(object["description"]),
            maxContextLength: Self.int(object["max_context_length"]),
            aliases: Self.stringArray(object["aliases"]),
            deprecation: Self.date(object["deprecation"]),
            deprecationReplacementModel: Self.string(object["deprecation_replacement_model"]),
            defaultModelTemperature: Self.double(object["default_model_temperature"]),
            type: Self.string(object["type"]),
            job: Self.string(object["job"]),
            root: Self.string(object["root"]),
            archived: Self.optionalBool(object["archived"]))
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(describing: value)
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { Self.string($0) }
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        self.optionalBool(value) ?? false
    }

    private static func optionalBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let raw = Self.string(value) else { return nil }
        return Self.date(fromBillingString: raw)
    }

    private static func date(fromBillingString raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func capitalized(_ kind: String) -> String {
        kind.prefix(1).uppercased() + kind.dropFirst()
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func makeISO8601DateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func makeRFC1123DateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }

    private static func makeHTTPDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }

    private static func buildPriceIndex(_ prices: [MistralPrice]) -> [String: Double] {
        var index: [String: Double] = [:]
        for price in prices {
            guard let metric = price.billingMetric,
                  let group = price.billingGroup,
                  let rawPrice = price.price,
                  let amount = Double(rawPrice)
            else {
                continue
            }
            index["\(metric)|\(group)"] = amount
        }
        return index
    }

    private static func categoryModelMaps(from billing: MistralBillingResponse) -> [[String: MistralModelUsageData]] {
        var categories: [[String: MistralModelUsageData]] = []
        if let item = billing.completion?.models, !item.isEmpty { categories.append(item) }
        if let item = billing.ocr?.models, !item.isEmpty { categories.append(item) }
        if let item = billing.connectors?.models, !item.isEmpty { categories.append(item) }
        if let item = billing.audio?.models, !item.isEmpty { categories.append(item) }
        if let item = billing.librariesApi?.pages?.models, !item.isEmpty { categories.append(item) }
        if let item = billing.librariesApi?.tokens?.models, !item.isEmpty { categories.append(item) }
        if let item = billing.fineTuning?.training, !item.isEmpty { categories.append(item) }
        if let item = billing.fineTuning?.storage, !item.isEmpty { categories.append(item) }
        return categories
    }

    private static func aggregateModelUsage(
        _ data: MistralModelUsageData,
        prices: [String: Double]) -> (input: Int, output: Int, cached: Int, cost: Double)
    {
        let input = Self.aggregateEntries(data.input, billingGroup: "input", prices: prices)
        let output = Self.aggregateEntries(data.output, billingGroup: "output", prices: prices)
        let cached = Self.aggregateEntries(data.cached, billingGroup: "cached", prices: prices)

        return (
            input: input.count,
            output: output.count,
            cached: cached.count,
            cost: input.cost + output.cost + cached.cost)
    }

    private static func aggregateEntries(
        _ entries: [MistralUsageEntry]?,
        billingGroup: String,
        prices: [String: Double]) -> (count: Int, cost: Double)
    {
        guard let entries, !entries.isEmpty else { return (0, 0) }
        var count = 0
        var cost = 0.0

        for entry in entries {
            let value = Int((entry.value ?? 0).rounded())
            let billableValue: Double = entry.valuePaid ?? entry.value ?? 0
            count += value

            if let metric = entry.billingMetric,
               let price = prices["\(metric)|\(billingGroup)"]
            {
                cost += billableValue * price
            }
        }

        return (count, cost)
    }

    private static func displayName(for modelKey: String, usageData: MistralModelUsageData) -> String {
        for entries in [usageData.input, usageData.output, usageData.cached] {
            if let name = entries?.compactMap({ $0.billingDisplayName }).first(where: { !$0.isEmpty }) {
                return name
            }
        }

        if let separator = modelKey.firstIndex(of: ":") {
            return String(modelKey[..<separator])
        }
        return modelKey
    }

    private static func parseWorkspaceSnapshots(
        root: [String: Any]?,
        prices: [String: Double]) -> [MistralWorkspaceUsageSnapshot]
    {
        guard let root else { return [] }
        let keys = ["workspaces", "by_workspace", "workspace_usage"]

        for key in keys {
            if let dictionary = root[key] as? [String: Any] {
                let snapshots = dictionary.compactMap { name, value -> MistralWorkspaceUsageSnapshot? in
                    guard let payload = value as? [String: Any] else { return nil }
                    return self.workspaceSnapshot(name: name, payload: payload, prices: prices)
                }
                if !snapshots.isEmpty {
                    return snapshots.sorted { $0.totalCost > $1.totalCost }
                }
            }

            if let array = root[key] as? [Any] {
                let snapshots = array.compactMap { value -> MistralWorkspaceUsageSnapshot? in
                    guard let payload = value as? [String: Any] else { return nil }
                    let workspaceName = self.string(payload["name"])
                        ?? self.string(payload["workspace_name"])
                        ?? self.string(payload["slug"])
                        ?? self.string(payload["id"])
                    guard let workspaceName, !workspaceName.isEmpty else { return nil }
                    return self.workspaceSnapshot(name: workspaceName, payload: payload, prices: prices)
                }
                if !snapshots.isEmpty {
                    return snapshots.sorted { $0.totalCost > $1.totalCost }
                }
            }
        }

        return []
    }

    private static func workspaceSnapshot(
        name: String,
        payload: [String: Any],
        prices: [String: Double]) -> MistralWorkspaceUsageSnapshot?
    {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let billing = try? JSONDecoder().decode(MistralBillingResponse.self, from: data)
        else {
            return nil
        }

        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCachedTokens = 0
        var totalCost = 0.0
        var modelNames: Set<String> = []

        for category in self.categoryModelMaps(from: billing) {
            for (modelKey, usageData) in category {
                let modelTotals = self.aggregateModelUsage(usageData, prices: prices)
                totalInputTokens += modelTotals.input
                totalOutputTokens += modelTotals.output
                totalCachedTokens += modelTotals.cached
                totalCost += modelTotals.cost

                let displayName = self.displayName(for: modelKey, usageData: usageData)
                if !displayName.isEmpty {
                    modelNames.insert(displayName)
                }
            }
        }

        guard totalInputTokens > 0 || totalOutputTokens > 0 || totalCachedTokens > 0 || totalCost > 0 else {
            return nil
        }

        return MistralWorkspaceUsageSnapshot(
            name: name,
            totalCost: totalCost,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCachedTokens: totalCachedTokens,
            modelCount: modelNames.count)
    }
}
