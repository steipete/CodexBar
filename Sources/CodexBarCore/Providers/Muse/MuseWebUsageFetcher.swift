import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Team usage via dev.meta.ai GraphQL — reverse-engineered from HAR 2026-08-15.
// The dashboard at https://dev.meta.ai/usage/?project_id=...&team_id=...
// loads via POST https://dev.meta.ai/api/graphql/ with
//   fb_api_caller_class=RelayModern
//   fb_api_req_friendly_name=LLMDCUsageQuery
//   doc_id=27710687895239709
//   variables={api_key_id, end_date, model_id, start_date, team_id, timezone, ...}
// Auth is browser cookies (dev.meta.ai). We replicate the request with
// Cookie header + standard Comet headers; dynamic __* tokens are best-effort
// (extracted from HTML when available) but many deployments accept minimal
// GraphQL body alone.

public enum MuseWebUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.muse, scope: "web-usage"))
    private static let dashboardURL = URL(string: "https://dev.meta.ai/usage")!
    private static let graphQLURL = URL(string: "https://dev.meta.ai/api/graphql/")!
    // doc_id for LLMDCUsageQuery — stable in HAR; if Meta rotates it we
    // fall back to HTML/legacy parsing and surface parseFailed
    private static let usageDocID = "27710687895239709"
    private static let fallbackDocIDAlt = "27710687895239709"

    public static func fetchUsage(
        cookieHeader: String,
        timeout: TimeInterval = 15,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> UsageSnapshot
    {
        // 1) Try GraphQL usage (primary)
        if let snap = try await self.fetchViaGraphQL(
            cookieHeader: cookieHeader,
            timeout: timeout,
            transport: transport)
        {
            return snap
        }
        // 2) Fallback: fetch HTML and look for embedded usage (kept for diagnostics)
        var htmlRequest = URLRequest(url: self.dashboardURL, timeoutInterval: timeout)
        htmlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        htmlRequest.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        let htmlResponse = try await transport.response(for: htmlRequest)
        guard (200..<300).contains(htmlResponse.statusCode) else {
            if htmlResponse.statusCode == 401 || htmlResponse.statusCode == 403 {
                throw MuseUsageError.apiError("HTTP \(htmlResponse.statusCode) — invalid dev.meta.ai session")
            }
            throw MuseUsageError.apiError("HTTP \(htmlResponse.statusCode) at /usage")
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
        transport: any ProviderHTTPTransport) async throws -> UsageSnapshot?
    {
        // Fetch dashboard HTML first to harvest dynamic Comet tokens and team_id.
        // If that fetch fails we still attempt GraphQL with a minimal body.
        var teamId: String?
        var lsd: String?
        var fbDtsg: String?
        var rev: String?
        var hsi: String?
        do {
            var req = URLRequest(url: self.dashboardURL, timeoutInterval: timeout)
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept")
            let resp = try await transport.response(for: req)
            if (200..<300).contains(resp.statusCode), let html = String(data: resp.data, encoding: .utf8) {
                teamId = self.extractTeamId(from: html)
                lsd = self.extractLSD(from: html)
                fbDtsg = self.extractFbDtsg(from: html)
                rev = self.extractRev(from: html)
                hsi = self.extractHsi(from: html)
                if teamId == nil {
                    teamId = self.extractTeamId(from: resp.data)
                }
            }
        } catch {
            self.log.debug("Muse GraphQL prefetch HTML failed: \(error)")
        }

        // If we still have no teamId, try to discover via a lightweight
        // settings query could be added here. For now, surface a clear error
        // so callers fall back to API-key probe rather than 400-looping.
        guard let tid = teamId else {
            self.log.debug("Muse GraphQL: no team_id found in HTML — skipping GraphQL, falling back to HTML parse")
            return nil
        }

        let dates = self.weekWindow(timeZone: TimeZone(identifier: "America/Chicago") ?? .current)
        let variables: [String: Any] = [
            "api_key_id": NSNull(),
            "end_date": dates.end,
            "model_id": NSNull(),
            "start_date": dates.start,
            "team_id": tid,
            "timezone": "America/Chicago",
            "__relay_internal__pv__Usage_ShouldIncludeBatchMetricsrelayprovider": false,
            "__relay_internal__pv__Usage_ShouldIncludeCostMetricsrelayprovider": true,
        ]
        guard let variablesJSON = try? JSONSerialization.data(withJSONObject: variables),
              let variablesString = String(data: variablesJSON, encoding: .utf8) else { return nil }

        var bodyParams: [String: String] = [
            "av": "1530727316779396",
            "__user": "0",
            "__a": "1",
            "__req": "1",
            "__hs": "20680.HYP:comet_plat_default_pkg.2.1...0",
            "dpr": "2",
            "__ccg": "EXCELLENT",
            "__rev": rev ?? "1045266458",
            "__s": "qd8x56:htjz0d:eqz030",
            "__hsi": hsi ?? "7674111655354614736",
            "__comet_req": "71",
            "fb_dtsg": fbDtsg ?? "",
            "jazoest": "25548",
            "lsd": lsd ?? "Udy05zOkCC_e4JXEF5WQUL",
            "__spin_r": rev ?? "1045266458",
            "__spin_b": "trunk",
            "__spin_t": String(Int(Date().timeIntervalSince1970)),
            "fb_api_caller_class": "RelayModern",
            "fb_api_req_friendly_name": "LLMDCUsageQuery",
            "server_timestamps": "true",
            "variables": variablesString,
            "doc_id": self.usageDocID,
        ]
        // Omit empty fb_dtsg if we didn't find one — some sessions work without it
        if bodyParams["fb_dtsg"]?.isEmpty == true { bodyParams.removeValue(forKey: "fb_dtsg") }

        let bodyString = bodyParams.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
        }.joined(separator: "&")
        guard let bodyData = bodyString.data(using: .utf8) else { return nil }

        var request = URLRequest(url: self.graphQLURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://dev.meta.ai/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://dev.meta.ai", forHTTPHeaderField: "Origin")
        request.setValue("LLMDCUsageQuery", forHTTPHeaderField: "X-FB-Friendly-Name")
        if let l = lsd { request.setValue(l, forHTTPHeaderField: "X-FB-LSD") }

        let response = try await transport.response(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw MuseUsageError.apiError("HTTP \(response.statusCode) — invalid dev.meta.ai session (GraphQL)")
        }
        guard (200..<300).contains(response.statusCode) else {
            self.log.error("Muse GraphQL returned HTTP \(response.statusCode)")
            // Don't throw — let caller fall back to HTML
            return nil
        }
        // Response may be JSON or JS-wrapped JSON (for(...);). Strip prefix.
        let data = self.stripJSWrapper(response.data)
        if let snap = try self.parseUsageGraphQL(data: data) { return snap }
        // Log a snippet for diagnostics (capped)
        if let raw = String(data: data, encoding: .utf8) {
            self.log.debug("Muse GraphQL parseFailed, snippet: \(raw.prefix(600))")
        }
        return nil
    }

    private static func weekWindow(timeZone: TimeZone) -> (start: String, end: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let now = Date()
        let end = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -6, to: end) ?? end
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return (fmt.string(from: start), fmt.string(from: end))
    }

    static func stripJSWrapper(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("for(;;);") {
            let after = String(trimmed.dropFirst("for(;;);".count))
            return Data(after.utf8)
        }
        return data
    }

    static func parseUsageGraphQL(data: Data) throws -> UsageSnapshot? {
        // Muse LLMD-C shape: data.team.{requests_metrics,input_token_metrics,output_token_metrics,spend_cost_metrics}
        if let snap = parseTeamUsage(data: data) { return snap }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        /// Common Comet shape: {data: {viewer: {team: {usage: {...}}}}} or {data: {llmdc_usage: {...}}}
        /// We recursively search for token/cost keys.
        func findMetrics(
            _ dict: [String: Any],
            depth: Int = 0) -> (tokens: Double?, cost: Double?, requests: Double?)?
        {
            if depth > 8 { return nil }
            var tokens: Double?
            var cost: Double?
            var requests: Double?
            for (k, v) in dict {
                let lk = k.lowercased()
                if lk.contains("total_tokens") || lk == "totaltokens" || lk == "total_tokens_used" {
                    if let d = v as? Double { tokens = d }
                    if tokens == nil, let i = v as? Int { tokens = Double(i) }
                    if tokens == nil, let s = v as? String, let d = Double(s) { tokens = d }
                }
                if lk.contains("cost") || lk == "total_cost" || lk == "amount" {
                    if let d = v as? Double { cost = d }
                    if cost == nil, let i = v as? Int { cost = Double(i) }
                    if cost == nil, let s = v as? String, let d = Double(s) { cost = d }
                }
                if lk.contains("request"), lk.contains("count") || lk.contains("total") {
                    if let d = v as? Double { requests = d }
                    if requests == nil, let i = v as? Int { requests = Double(i) }
                }
                if let nested = v as? [String: Any], let found = findMetrics(nested, depth: depth + 1) {
                    tokens = tokens ?? found.tokens; cost = cost ?? found.cost; requests = requests ?? found.requests
                }
                if let arr = v as? [[String: Any]] {
                    for e in arr {
                        if let found = findMetrics(e, depth: depth + 1) {
                            tokens = tokens ?? found.tokens; cost = cost ?? found.cost; requests = requests ?? found
                                .requests
                        }
                    }
                }
            }
            if tokens != nil || cost != nil || requests != nil { return (tokens, cost, requests) }
            return nil
        }
        // Also handle top-level array shape from relay-ef batch
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in arr {
                if let m = findMetrics(e),
                   m.tokens != nil || m.cost != nil { return Self.snapshot(from: m) }
            }
        }
        if let metrics = findMetrics(obj), metrics.tokens != nil || metrics.cost != nil || metrics.requests != nil {
            return Self.snapshot(from: metrics)
        }
        // Fallback: look inside "data" key one level deeper
        if let dataDict = obj["data"] as? [String: Any], let metrics = findMetrics(dataDict) {
            return Self.snapshot(from: metrics)
        }
        return nil
    }

    // MARK: - LLMD-C team usage (meta.ai)

    static func parseTeamUsage(data: Data) -> UsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = obj["data"] as? [String: Any],
              let team = dataDict["team"] as? [String: Any] else { return nil }

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

        let requests = sumCategorical(in: "requests_metrics", identifier: "num_requests")
        let promptTokens = sumCategorical(in: "input_token_metrics", identifier: "num_prompt_tokens")
        let outputTokens = sumCategorical(in: "output_token_metrics", identifier: "num_completion_tokens")
        let totalTokens = (promptTokens ?? 0) + (outputTokens ?? 0)
        let cost = sumCategorical(in: "spend_cost_metrics", identifier: "usage_billable_cost")

        guard requests != nil || promptTokens != nil || outputTokens != nil || cost != nil else { return nil }

        var parts: [String] = []
        if let r = requests { parts.append("\(Int(r)) requests") }
        if totalTokens > 0 { parts.append("\(Int(totalTokens)) tokens") }
        if let c = cost, c > 0 { parts.append(String(format: "$%.2f", c)) }
        // Daily breakdown for the last value (today) — useful for quick glance
        let todayRequests = (team["requests_metrics"] as? [[String: Any]])?
            .first(where: { $0["identifier"] as? String == "num_requests" })?["categorical_data"] as? [[String: Any]]
        _ = todayRequests
        let login = parts.isEmpty ? "Team usage" : "Team usage: \(parts.joined(separator: " · "))"
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: login)
        // Surface totals as cost snapshot (balanceOnly provider — bars stay empty)
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: cost.map {
                ProviderCostSnapshot(
                    used: $0,
                    limit: $0,
                    currencyCode: "USD",
                    updatedAt: Date())
            },
            updatedAt: Date(),
            identity: identity)
    }

    private static func snapshot(from metrics: (tokens: Double?, cost: Double?, requests: Double?)) -> UsageSnapshot {
        var parts: [String] = []
        if let t = metrics.tokens { parts.append("\(Int(t)) tokens") }
        if let c = metrics.cost { parts.append(String(format: "$%.2f", c)) }
        if let r = metrics.requests { parts.append("\(Int(r)) req") }
        let login = parts.isEmpty ? "Team usage" : "Team usage: \(parts.joined(separator: " · "))"
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: login)
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
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
        if let r = html.range(of: #""LSD"\s*,\s*\[\]\s*,\s*\{"token"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let sub = String(html[r])
            if let m = sub.range(of: #""token"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                let t = String(sub[m])
                return t.components(separatedBy: "\"").dropLast(1).last
            }
        }
        // fallback: lsd=....
        if let r = html.range(of: #"\"lsd\"\s*:\s*\"([^\"]+)\""#, options: .regularExpression) {
            let sub = String(html[r])
            if let m = sub.range(of: #"[A-Za-z0-9_-]{6,}"#, options: .regularExpression) { return String(sub[m]) }
        }
        return nil
    }

    static func extractFbDtsg(from html: String) -> String? {
        // fb_dtsg or DTSG token
        if let r = html.range(of: #"\"dtsg\"\s*:\s*\{"token"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let sub = String(html[r])
            // extract quoted value
            let comps = sub.components(separatedBy: "\"")
            if let idx = comps.firstIndex(of: "token"), idx + 2 < comps.count { return comps[idx + 2] }
        }
        if let r = html.range(of: #"fb_dtsg[^"]*"([^"]{10,})"#, options: .regularExpression) {
            let sub = String(html[r])
            if let m = sub.range(of: #"[A-Za-z0-9:_-]{10,}"#, options: .regularExpression) { return String(sub[m]) }
        }
        return nil
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

    static func parseUsageAPI(data: Data) throws -> UsageSnapshot? {
        // Kept for legacy fallback — same as before
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let totalKeys = ["total_tokens", "totalTokens", "total_tokens_used", "total"]
        let inputKeys = ["input_tokens", "inputTokens"]
        let outputKeys = ["output_tokens", "outputTokens"]
        var total: Double?
        var input: Double?
        var output: Double?
        for k in totalKeys {
            if let v = obj[k] as? Double { total = v; break }; if let v = obj[k] as? Int { total = Double(v); break }
        }
        for k in inputKeys {
            if let v = obj[k] as? Double { input = v; break }; if let v = obj[k] as? Int { input = Double(v); break }
        }
        for k in outputKeys {
            if let v = obj[k] as? Double { output = v; break }; if let v = obj[k] as? Int { output = Double(v); break }
        }
        if total == nil, let nested = obj["data"] as? [String: Any] {
            for k in totalKeys {
                if let v = nested[k] as? Double { total = v; break }; if let v = nested[k] as? Int {
                    total = Double(v); break
                }
            }
        }
        guard let t = total ?? (input != nil || output != nil ? (input ?? 0) + (output ?? 0) : nil),
              t > 0 else { return nil }
        let login = "Team usage: \(Int(t)) tokens"
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: login)
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    static func parseDashboardHTML(data: Data) throws -> UsageSnapshot? {
        guard let html = String(data: data, encoding: .utf8),
              html.contains("Team usage") || html.contains("total tokens") || html.contains("Token usage")
        else { return nil }
        return nil
    }
}
