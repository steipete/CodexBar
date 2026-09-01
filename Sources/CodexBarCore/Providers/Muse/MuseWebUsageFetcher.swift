import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Team usage via the Relay operation used by dev.meta.ai. Authentication comes
// from the user's current browser profile. Request-scoped Comet values are read
// from the matching dashboard HTML and are never replayed from a captured HAR.

public enum MuseWebUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.muse, scope: "web-usage"))
    // Meta's client router canonicalizes the bare path to a team/project-qualified URL.
    // The non-canonical path currently returns HTTP 500 outside a browser instead of redirecting.
    private static let defaultDashboardURL = URL(string: "https://dev.meta.ai/usage/")!
    private static let defaultBootstrapURL = URL(string: "https://dev.meta.ai/")!
    private static let graphQLURL = URL(string: "https://dev.meta.ai/api/graphql/")!
    private static let usageDocID = "28117303444603430"
    private static let defaultBrowserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"

    public static func fetchUsage(
        cookieHeader: String,
        timeout: TimeInterval = 15,
        dashboardURL: URL? = nil,
        userAgent: String? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> UsageSnapshot
    {
        let dashboardURL = dashboardURL ?? self.defaultDashboardURL
        // 1) Try GraphQL usage (primary)
        if let snap = try await self.fetchViaGraphQL(
            cookieHeader: cookieHeader,
            timeout: timeout,
            dashboardURL: dashboardURL,
            userAgent: userAgent,
            transport: transport)
        {
            return snap
        }
        // 2) Fallback: fetch HTML and look for embedded usage (kept for diagnostics)
        var htmlRequest = URLRequest(url: dashboardURL, timeoutInterval: timeout)
        self.applyBrowserHeaders(to: &htmlRequest, cookieHeader: cookieHeader, userAgent: userAgent)
        htmlRequest.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        let htmlResponse = try await transport.response(for: htmlRequest)
        guard (200..<300).contains(htmlResponse.statusCode) else {
            if htmlResponse.statusCode == 401 || htmlResponse.statusCode == 403 {
                throw MuseUsageError.apiError("HTTP \(htmlResponse.statusCode) — invalid dev.meta.ai session")
            }
            throw MuseUsageError.apiError("HTTP \(htmlResponse.statusCode) at /usage/")
        }
        if let snap = try self.parseDashboardHTML(data: htmlResponse.data) { return snap }
        throw MuseUsageError
            .parseFailed(
                "No parseable usage on dev.meta.ai/usage — GraphQL returned no usage and HTML had no embedded data")
    }

    // MARK: - GraphQL

    private static func fetchViaGraphQL(
        cookieHeader: String,
        timeout: TimeInterval,
        dashboardURL: URL,
        userAgent: String?,
        transport: any ProviderHTTPTransport) async throws -> UsageSnapshot?
    {
        let bootstrapData = try await self.fetchBootstrapHTML(
            cookieHeader: cookieHeader,
            timeout: timeout,
            dashboardURL: dashboardURL,
            userAgent: userAgent,
            transport: transport)
        guard let html = String(data: bootstrapData, encoding: .utf8) else {
            throw MuseUsageError.parseFailed("Invalid UTF-8 response from dev.meta.ai")
        }
        guard let teamID = self.extractTeamId(from: html) ?? self.queryValue(named: "team_id", in: dashboardURL) else {
            throw MuseUsageError.apiError(
                "The selected browser session has no dev.meta.ai team. Open Team usage in that browser first.")
        }

        let dates = self.recentSevenDayWindow(timeZone: .current)
        let variables: [String: Any] = [
            "api_key_id": NSNull(),
            "end_date": dates.end,
            "model_id": NSNull(),
            "month": NSNull(),
            "start_date": dates.start,
            "team_id": teamID,
            "__relay_internal__pv__Usage_ShouldIncludeBatchMetricsrelayprovider": false,
            "__relay_internal__pv__Usage_ShouldIncludeCostMetricsrelayprovider": true,
            "__relay_internal__pv__Usage_ShouldIncludeImageMetricsrelayprovider": true,
            "__relay_internal__pv__Usage_ShouldIncludeSubscriptionQuotarelayprovider": true,
        ]
        guard let variablesJSON = try? JSONSerialization.data(withJSONObject: variables),
              let variablesString = String(data: variablesJSON, encoding: .utf8) else { return nil }

        var bodyParams: [String: String] = [
            "__a": "1",
            "fb_api_caller_class": "RelayModern",
            "fb_api_req_friendly_name": "LLMDCUsageQuery",
            "server_timestamps": "true",
            "variables": variablesString,
            "doc_id": self.usageDocID,
        ]
        let lsd = self.extractLSD(from: html)
        if let lsd { bodyParams["lsd"] = lsd }
        if let fbDtsg = self.extractFbDtsg(from: html) {
            bodyParams["fb_dtsg"] = fbDtsg
            bodyParams["jazoest"] = self.jazoest(for: fbDtsg)
        }
        if let actorID = self.extractActorID(from: html) {
            bodyParams["av"] = actorID
            bodyParams["__user"] = actorID
        }
        if let rev = self.extractRev(from: html) { bodyParams["__rev"] = rev }
        if let hsi = self.extractHsi(from: html) { bodyParams["__hsi"] = hsi }

        guard let bodyData = self.formData(bodyParams) else { return nil }

        var request = URLRequest(url: self.graphQLURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        self.applyBrowserHeaders(to: &request, cookieHeader: cookieHeader, userAgent: userAgent)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://dev.meta.ai", forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("LLMDCUsageQuery", forHTTPHeaderField: "X-FB-Friendly-Name")
        if let lsd { request.setValue(lsd, forHTTPHeaderField: "X-FB-LSD") }

        let response = try await transport.response(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw MuseUsageError.apiError("HTTP \(response.statusCode) — invalid dev.meta.ai session (GraphQL)")
        }
        guard (200..<300).contains(response.statusCode) else {
            self.log.error("Muse GraphQL returned HTTP \(response.statusCode)")
            throw MuseUsageError.apiError("HTTP \(response.statusCode) from dev.meta.ai GraphQL")
        }
        // Response may be JSON or JS-wrapped JSON (for(...);). Strip prefix.
        let data = self.stripJSWrapper(response.data)
        self.log.debug("Muse GraphQL response shape: \(self.responseShape(data))")
        if let snap = try self.parseUsageGraphQL(data: data) { return snap }
        if let graphQLError = self.graphQLError(from: data) {
            self.log.error("Muse GraphQL rejected the request: \(graphQLError)")
            throw MuseUsageError.apiError(graphQLError)
        }
        if let snap = try self.parseDashboardHTML(data: bootstrapData) { return snap }
        self.log.debug("Muse GraphQL returned no recognized usage payload")
        return nil
    }

    private static func fetchBootstrapHTML(
        cookieHeader: String,
        timeout: TimeInterval,
        dashboardURL: URL,
        userAgent: String?,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        let dashboardResponse = try await self.fetchHTML(
            url: dashboardURL,
            cookieHeader: cookieHeader,
            timeout: timeout,
            userAgent: userAgent,
            transport: transport)
        if (200..<300).contains(dashboardResponse.statusCode) {
            return dashboardResponse.data
        }
        if dashboardResponse.statusCode == 401 || dashboardResponse.statusCode == 403 {
            throw MuseUsageError.apiError(
                "HTTP \(dashboardResponse.statusCode) — invalid dev.meta.ai browser session")
        }

        // The usage page is a client-side route. Meta currently returns HTTP 500
        // when it is requested directly outside the browser navigation that created
        // the SPA, even though the same browser session is valid. Bootstrap Comet
        // tokens from the app shell and retain the scoped usage URL as the Referer.
        let rootResponse = try await self.fetchHTML(
            url: self.scopedBootstrapURL(dashboardURL: dashboardURL),
            cookieHeader: cookieHeader,
            timeout: timeout,
            userAgent: userAgent,
            transport: transport)
        if (200..<300).contains(rootResponse.statusCode) {
            return rootResponse.data
        }
        if rootResponse.statusCode == 401 || rootResponse.statusCode == 403 {
            throw MuseUsageError.apiError(
                "HTTP \(rootResponse.statusCode) — invalid dev.meta.ai browser session")
        }

        // Meta may reject document navigation from URLSession while still accepting
        // its Relay endpoint with the same browser cookies. The scoped route carries
        // the team identity, so continue without optional Comet tokens in that case.
        if self.queryValue(named: "team_id", in: dashboardURL) != nil,
           self.queryValue(named: "project_id", in: dashboardURL) != nil
        {
            return Data()
        }
        throw MuseUsageError.apiError("HTTP \(dashboardResponse.statusCode) at /usage/")
    }

    private static func fetchHTML(
        url: URL,
        cookieHeader: String,
        timeout: TimeInterval,
        userAgent: String?,
        transport: any ProviderHTTPTransport) async throws -> ProviderHTTPResponse
    {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        self.applyBrowserHeaders(to: &request, cookieHeader: cookieHeader, userAgent: userAgent)
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("?0", forHTTPHeaderField: "Sec-CH-UA-Mobile")
        request.setValue(#""macOS""#, forHTTPHeaderField: "Sec-CH-UA-Platform")
        request.setValue(self.clientHints(userAgent: userAgent), forHTTPHeaderField: "Sec-CH-UA")
        request.setValue("u=0, i", forHTTPHeaderField: "Priority")
        return try await transport.response(for: request)
    }

    static func scopedBootstrapURL(dashboardURL: URL) -> URL {
        guard let dashboard = URLComponents(url: dashboardURL, resolvingAgainstBaseURL: false) else {
            return self.defaultBootstrapURL
        }
        var root = URLComponents()
        root.scheme = "https"
        root.host = "dev.meta.ai"
        root.path = "/"
        root.queryItems = dashboard.queryItems?.filter { $0.name == "team_id" || $0.name == "project_id" }
        return root.url ?? self.defaultBootstrapURL
    }

    private static func recentSevenDayWindow(timeZone: TimeZone) -> (start: String, end: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let end = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -6, to: end) ?? end
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return (fmt.string(from: start), fmt.string(from: end))
    }

    private static func applyBrowserHeaders(
        to request: inout URLRequest,
        cookieHeader: String,
        userAgent: String?)
    {
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent ?? self.defaultBrowserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    private static func clientHints(userAgent: String?) -> String {
        let userAgent = userAgent ?? self.defaultBrowserUserAgent
        let majorVersion = self.firstCapture(in: userAgent, patterns: [#"Chrome/(\d+)"#]) ?? "152"
        return #""Not_A Brand";v="99", "Chromium";v="\#(majorVersion)""#
    }

    static func formData(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    static func graphQLError(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errors = object["errors"] as? [[String: Any]],
           let first = errors.first,
           let message = first["message"] as? String
        {
            if let code = first["code"] as? Int {
                return "GraphQL \(code): \(message)"
            }
            return "GraphQL: \(message)"
        }
        if let code = object["error"] as? Int, code != 0 {
            let summary = object["errorSummary"] as? String
            let description = object["errorDescription"] as? String
            let message = [summary, description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
            return message.isEmpty ? "GraphQL \(code)" : "GraphQL \(code): \(message)"
        }
        return nil
    }

    static func jazoest(for token: String) -> String {
        "2\(token.unicodeScalars.reduce(0) { $0 + Int($1.value) })"
    }

    static func queryValue(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    static func stripJSWrapper(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let guardRange = trimmed.range(
            of: #"^for\s*\(\s*;;\s*\)\s*;"#,
            options: .regularExpression)
        {
            return Data(trimmed[guardRange.upperBound...].utf8)
        }
        return data
    }

    static func responseShape(_ data: Data) -> String {
        func shape(_ value: Any, depth: Int = 0) -> String {
            guard depth < 4 else { return "…" }
            if let dictionary = value as? [String: Any] {
                let contents = dictionary.keys.sorted().prefix(24).map { key in
                    "\(key):\(shape(dictionary[key] as Any, depth: depth + 1))"
                }.joined(separator: ",")
                return "{\(contents)}"
            }
            if let array = value as? [Any] {
                let first = array.first.map { shape($0, depth: depth + 1) } ?? "empty"
                return "[count=\(array.count),first=\(first)]"
            }
            if value is NSNull { return "null" }
            if value is String { return "string" }
            if value is NSNumber { return "number" }
            return String(describing: type(of: value))
        }

        if let object = try? JSONSerialization.jsonObject(with: data) {
            return shape(object)
        }
        let lines = data.split(separator: 0x0A).filter { !$0.isEmpty }
        let lineShapes = lines.prefix(8).map { line -> String in
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) {
                return shape(object)
            }
            return "non-json"
        }
        let prefix = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "bytes=\(data.count),hexPrefix=\(prefix),lines=[\(lineShapes.joined(separator: ","))]"
    }

    static func parseUsageGraphQL(data: Data) throws -> UsageSnapshot? {
        // Muse LLMD-C shape: data.team.spend_cost_metrics. Token and request metrics are intentionally ignored:
        // Muse is pay-as-you-go, so spend is the user-facing usage signal.
        if let snap = parseTeamUsage(data: data) { return snap }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        /// Common Comet shape: {data: {viewer: {team: {usage: {...}}}}} or {data: {llmdc_usage: {...}}}
        /// We recursively search only for cost keys.
        func findCost(_ value: Any, depth: Int = 0) -> Double? {
            if depth > 8 { return nil }
            if let dictionary = value as? [String: Any] {
                for (key, nested) in dictionary {
                    let normalizedKey = key.lowercased()
                    if normalizedKey.contains("cost") || normalizedKey == "amount" {
                        if let cost = nested as? Double { return cost }
                        if let cost = nested as? Int { return Double(cost) }
                        if let string = nested as? String, let cost = Double(string) { return cost }
                    }
                }
                for nested in dictionary.values {
                    if let cost = findCost(nested, depth: depth + 1) { return cost }
                }
            } else if let array = value as? [Any] {
                for nested in array {
                    if let cost = findCost(nested, depth: depth + 1) { return cost }
                }
            }
            return nil
        }
        // Also handle top-level array shape from relay-ef batch
        if let arr = object as? [[String: Any]] {
            for e in arr {
                if let cost = findCost(e) { return Self.spendSnapshot(cost: cost) }
            }
        }
        guard let obj = object as? [String: Any] else { return nil }
        if let cost = findCost(obj) {
            return Self.spendSnapshot(cost: cost)
        }
        // Fallback: look inside "data" key one level deeper
        if let dataDict = obj["data"] as? [String: Any], let cost = findCost(dataDict) {
            return Self.spendSnapshot(cost: cost)
        }
        return nil
    }

    // MARK: - LLMD-C team usage (meta.ai)

    static func parseTeamUsage(data: Data) -> UsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let metricsKeys = ["spend_cost_metrics"]
        func findTeam(in value: Any, depth: Int = 0) -> [String: Any]? {
            guard depth <= 10 else { return nil }
            if let dictionary = value as? [String: Any] {
                if metricsKeys.contains(where: { dictionary[$0] != nil }) {
                    return dictionary
                }
                if let team = dictionary["team"] as? [String: Any],
                   metricsKeys.contains(where: { team[$0] != nil })
                {
                    return team
                }
                for nested in dictionary.values {
                    if let team = findTeam(in: nested, depth: depth + 1) { return team }
                }
            } else if let array = value as? [Any] {
                for nested in array {
                    if let team = findTeam(in: nested, depth: depth + 1) { return team }
                }
            }
            return nil
        }

        guard let team = findTeam(in: object) else { return nil }

        func sumCategorical(in metricsKey: String, identifier: String) -> Double? {
            guard let arr = team[metricsKey] as? [[String: Any]] else { return nil }
            for entry in arr where (entry["identifier"] as? String) == identifier {
                guard let cat = entry["categorical_data"] as? [[String: Any]] else { continue }
                var sum: Double = 0
                var hasValue = false
                for point in cat {
                    if let v = point["value"] as? Int { sum += Double(v); hasValue = true; continue }
                    if let v = point["value"] as? Double { sum += v; hasValue = true; continue }
                    if let dict = point["value"] as? [String: Any],
                       let amt = dict["amount_with_offset"] as? String,
                       let cents = Double(amt)
                    {
                        sum += cents / 100.0; hasValue = true; continue
                    }
                    if let dict = point["value"] as? [String: Any],
                       let amt = dict["amount_with_offset"] as? Int
                    {
                        sum += Double(amt) / 100.0; hasValue = true
                    }
                }
                if hasValue { return sum }
            }
            return nil
        }

        guard let cost = sumCategorical(in: "spend_cost_metrics", identifier: "usage_billable_cost") else {
            return nil
        }

        let dailyPoints = Self.dailyCostPoints(from: team)

        let detailRows: [ProviderDetailSection.Row] = dailyPoints.compactMap { pt in
            try? ProviderDetailSection.Row(label: pt.dayKey, value: Self.localizedCost(pt.costUSD))
        }
        let detail: [ProviderDetailSection] = {
            guard !detailRows.isEmpty else { return [] }
            return (try? ProviderDetailSection(title: "Daily spend", rows: detailRows)).map { [$0] } ?? []
        }()

        let now = Date()
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: cost,
                limit: 0,
                currencyCode: "USD",
                period: "Last 7 days",
                updatedAt: now),
            details: detail,
            updatedAt: now,
            identity: nil)
    }

    private static func dailyCostPoints(from team: [String: Any])
        -> [(dayKey: String, costUSD: Double)]
    {
        guard let metrics = team["spend_cost_metrics"] as? [[String: Any]] else { return [] }
        var byDay: [String: Double] = [:]
        for entry in metrics where (entry["identifier"] as? String) == "usage_billable_cost" {
            guard let categoricalData = entry["categorical_data"] as? [[String: Any]] else { continue }
            for point in categoricalData {
                guard let day = point["category"] as? String,
                      let value = point["value"] as? [String: Any]
                else { continue }
                let cents = (value["amount_with_offset"] as? String).flatMap(Double.init)
                    ?? (value["amount_with_offset"] as? Int).map(Double.init)
                if let cents {
                    byDay[day] = cents / 100.0
                }
            }
        }
        return byDay.map { (dayKey: $0.key, costUSD: $0.value) }
            .sorted { $0.dayKey < $1.dayKey }
    }

    static func parseRenderedDashboardText(_ text: String) -> UsageSnapshot? {
        func capture(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: text,
                      range: NSRange(text.startIndex..<text.endIndex, in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }

        func decimal(_ value: String?) -> Double? {
            value.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }
        }

        guard let spend = decimal(capture(#"(?m)^\$([0-9][0-9,.]*)\s*\nSpend \(USD\)$"#)) else {
            return nil
        }
        return Self.spendSnapshot(cost: spend)
    }

    private static func spendSnapshot(cost: Double) -> UsageSnapshot {
        let now = Date()
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: cost,
                limit: 0,
                currencyCode: "USD",
                period: "Last 7 days",
                updatedAt: now),
            updatedAt: now,
            identity: nil)
    }

    // MARK: - Helpers for token extraction from HTML

    static func extractTeamId(from html: String) -> String? {
        // Handles: team_id=374..., "teamId":"374...", "teamId":374..., team_id:374..., teamId%3D374...
        let patterns = [
            #"team_id=(\d{5,})"#,
            #"team_id%3D(\d{5,})"#,
            #""teamId"\s*:\s*"?(\d{5,})"?""#,
            #""team_id"\s*:\s*"?(\d{5,})"?""#,
            #"teamId\\":\\?"?(\d{5,})\\?""#,
            #"team_id\\":\\?"?(\d{5,})\\?""#,
            #"\bteamId\b[^0-9]{0,20}(\d{10,})"#,
            #"\bteam_id\b[^0-9]{0,20}(\d{10,})"#,
        ]
        for pat in patterns {
            if let r = html.range(of: pat, options: .regularExpression) {
                let sub = String(html[r])
                if let m = sub.range(of: #"\d{10,}"#, options: .regularExpression) {
                    let candidate = String(sub[m])
                    // Avoid tiny IDs (5 digits) — real team_ids are ~16 digits
                    if candidate.count >= 10 { return candidate }
                }
            }
        }
        return nil
    }

    static func extractTeamId(from data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return self.extractTeamId(from: s)
    }

    static func extractLSD(from html: String) -> String? {
        self.firstCapture(in: html, patterns: [
            #""LSD"\s*,\s*\[\]\s*,\s*\{"token"\s*:\s*"([^"]+)""#,
            #""LSD".{0,240}"token"\s*:\s*"([^"]+)""#,
            #""lsd"\s*:\s*"([^"]+)""#,
        ])
    }

    static func extractFbDtsg(from html: String) -> String? {
        self.firstCapture(in: html, patterns: [
            #""DTSGInitialData".{0,320}"token"\s*:\s*"([^"]+)""#,
            #""DTSG".{0,320}"token"\s*:\s*"([^"]+)""#,
            #""dtsg"\s*:\s*\{"token"\s*:\s*"([^"]+)""#,
            #""fb_dtsg"\s*:\s*"([^"]{10,})""#,
        ])
    }

    static func extractActorID(from html: String) -> String? {
        guard let value = self.firstCapture(in: html, patterns: [
            #""USER_ID"\s*:\s*"(\d{5,})""#,
            #""ACCOUNT_ID"\s*:\s*"(\d{5,})""#,
            #""actorID"\s*:\s*"(\d{5,})""#,
            #""actor_id"\s*:\s*"(\d{5,})""#,
        ]), value != "0" else { return nil }
        return value
    }

    static func extractRev(from html: String) -> String? {
        if let r = html.range(of: #"\"__rev\"\s*:\s*(\d+)"#, options: .regularExpression) {
            let sub = String(html[r]); if let m = sub
                .range(of: #"\d{5,}"#, options: .regularExpression) { return String(sub[m]) }
        }
        if let r = html.range(of: #"__rev[=:](\d+)"#, options: .regularExpression) {
            let sub = String(html[r]); if let m = sub
                .range(of: #"\d{5,}"#, options: .regularExpression) { return String(sub[m]) }
        }
        return nil
    }

    static func extractHsi(from html: String) -> String? {
        if let r = html.range(of: #"\"hsi\"\s*:\s*"(\d+)""#, options: .regularExpression) {
            let sub = String(html[r]); if let m = sub
                .range(of: #"\d{10,}"#, options: .regularExpression) { return String(sub[m]) }
        }
        return nil
    }

    private static func firstCapture(in value: String, patterns: [String]) -> String? {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: value, range: searchRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value)
            else { continue }
            return String(value[range])
        }
        return nil
    }

    static func parseDashboardHTML(data: Data) throws -> UsageSnapshot? {
        guard let html = String(data: data, encoding: .utf8),
              html.contains("Team usage") || html.contains("total tokens") || html.contains("Token usage")
        else { return nil }
        return nil
    }

    // MARK: - Formatting

    private static func localizedCost(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale.current
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}
