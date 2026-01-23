import Foundation

struct CLIProxyAPIQuotaSnapshot: Sendable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let tertiary: RateWindow?
    let identity: ProviderIdentitySnapshot?
}

struct CLIProxyAPIQuotaFetcher: Sendable {
    private static let antigravityQuotaURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    ]
    private static let antigravityUserAgent = "antigravity/1.11.5 windows/amd64"
    private static let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let codexUserAgent = "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
    private static let geminiCLIQuotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let geminiIgnoredPrefixes = ["gemini-2.0-flash"]
    private static let antigravityDefaultProjectID = "bamboo-precept-lgxtn"

    private static let antigravityQuotaGroups: [(id: String, label: String, identifiers: [String])] = [
        ("claude-gpt", "Claude/GPT", [
            "claude-sonnet-4-5-thinking",
            "claude-opus-4-5-thinking",
            "claude-sonnet-4-5",
            "gpt-oss-120b-medium",
        ]),
        ("gemini-3-pro", "Gemini 3 Pro", ["gemini-3-pro-high", "gemini-3-pro-low"]),
        ("gemini-2-5-flash", "Gemini 2.5 Flash", ["gemini-2.5-flash", "gemini-2.5-flash-thinking"]),
        ("gemini-2-5-flash-lite", "Gemini 2.5 Flash Lite", ["gemini-2.5-flash-lite"]),
        ("gemini-2-5-cu", "Gemini 2.5 CU", ["rev19-uic3-1p"]),
        ("gemini-3-flash", "Gemini 3 Flash", ["gemini-3-flash"]),
        ("gemini-image", "gemini-3-pro-image", ["gemini-3-pro-image"]),
    ]

    static func fetchQuota(
        authFile: CLIProxyAPIAuthFile,
        authIndex: String,
        client: CLIProxyAPIManagementClient) async throws -> CLIProxyAPIQuotaSnapshot
    {
        let provider = authFile.normalizedProvider
        let identity = self.identitySnapshot(for: authFile)
        if authFile.disabled || authFile.unavailable {
            throw CLIProxyAPIQuotaError.unavailable
        }

        switch provider {
        case "codex":
            let result = try await self.fetchCodexQuota(authFile: authFile, authIndex: authIndex, client: client)
            return CLIProxyAPIQuotaSnapshot(
                primary: result.primary,
                secondary: result.secondary,
                tertiary: nil,
                identity: identity)
        case "gemini-cli":
            let result = try await self.fetchGeminiCLIQuota(
                authFile: authFile,
                authIndex: authIndex,
                client: client)
            return CLIProxyAPIQuotaSnapshot(
                primary: result.primary,
                secondary: result.secondary,
                tertiary: nil,
                identity: identity)
        case "antigravity":
            let result = try await self.fetchAntigravityQuota(
                authFile: authFile,
                authIndex: authIndex,
                client: client)
            return CLIProxyAPIQuotaSnapshot(
                primary: result.primary,
                secondary: result.secondary,
                tertiary: result.tertiary,
                identity: identity)
        default:
            throw CLIProxyAPIQuotaError.unsupportedProvider(provider)
        }
    }

    private static func fetchCodexQuota(
        authFile: CLIProxyAPIAuthFile,
        authIndex: String,
        client: CLIProxyAPIManagementClient) async throws -> (primary: RateWindow?, secondary: RateWindow?)
    {
        guard let accountID = await self.resolveCodexAccountID(authFile: authFile, client: client) else {
            throw CLIProxyAPIQuotaError.missingCodexAccountID
        }

        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": self.codexUserAgent,
            "Chatgpt-Account-Id": accountID,
        ]
        let response = try await client.apiCall(CLIProxyAPIApiCallRequest(
            authIndex: authIndex,
            method: "GET",
            url: self.codexUsageURL,
            header: headers,
            data: nil))

        if !(200..<300).contains(response.statusCode) {
            if let fallback = self.fallbackRateWindow(from: response.body) {
                return (fallback, nil)
            }
            throw CLIProxyAPIQuotaError.apiFailure(self.errorMessage(from: response.body))
        }

        guard let data = response.body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CLIProxyAPICodexUsagePayload.self, from: data)
        else {
            throw CLIProxyAPIQuotaError.invalidPayload
        }

        let primary = self.makeCodexWindow(
            window: payload.rateLimit?.primaryWindow,
            limitReached: payload.rateLimit?.limitReached,
            allowed: payload.rateLimit?.allowed)
        let secondary = self.makeCodexWindow(
            window: payload.rateLimit?.secondaryWindow,
            limitReached: payload.rateLimit?.limitReached,
            allowed: payload.rateLimit?.allowed)
        return (primary, secondary)
    }

    private static func fetchGeminiCLIQuota(
        authFile: CLIProxyAPIAuthFile,
        authIndex: String,
        client: CLIProxyAPIManagementClient) async throws -> (primary: RateWindow?, secondary: RateWindow?)
    {
        guard let projectID = self.resolveGeminiCLIProjectID(authFile: authFile) else {
            throw CLIProxyAPIQuotaError.missingProjectID
        }

        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
        ]
        let response = try await client.apiCall(CLIProxyAPIApiCallRequest(
            authIndex: authIndex,
            method: "POST",
            url: self.geminiCLIQuotaURL,
            header: headers,
            data: Self.jsonString(["project": projectID])))

        if !(200..<300).contains(response.statusCode) {
            if let fallback = self.fallbackRateWindow(from: response.body) {
                return (fallback, nil)
            }
            throw CLIProxyAPIQuotaError.apiFailure(self.errorMessage(from: response.body))
        }

        guard let data = response.body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CLIProxyAPIGeminiQuotaPayload.self, from: data)
        else {
            throw CLIProxyAPIQuotaError.invalidPayload
        }

        let buckets = payload.buckets ?? []
        let quotas = self.geminiModelQuotas(from: buckets)
        guard !quotas.isEmpty else {
            throw CLIProxyAPIQuotaError.invalidPayload
        }
        let snapshot = GeminiStatusSnapshot(
            modelQuotas: quotas,
            rawText: "",
            accountEmail: nil,
            accountPlan: nil)
        let usage = snapshot.toUsageSnapshot()
        return (usage.primary, usage.secondary)
    }

    private static func fetchAntigravityQuota(
        authFile: CLIProxyAPIAuthFile,
        authIndex: String,
        client: CLIProxyAPIManagementClient) async throws -> (primary: RateWindow?, secondary: RateWindow?, tertiary: RateWindow?)
    {
        let projectID = await self.resolveAntigravityProjectID(authFile: authFile, client: client)

        var lastError: String?
        for url in self.antigravityQuotaURLs {
            let headers = [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": self.antigravityUserAgent,
            ]
            let bodies = [
                Self.jsonString(["projectId": projectID]),
                Self.jsonString(["project": projectID]),
            ]
            for body in bodies {
                let response = try await client.apiCall(CLIProxyAPIApiCallRequest(
                    authIndex: authIndex,
                    method: "POST",
                    url: url,
                    header: headers,
                    data: body))

                if response.statusCode == 400,
                   self.isAntigravityUnknownFieldError(self.errorMessage(from: response.body) ?? "")
                {
                    lastError = self.errorMessage(from: response.body)
                    continue
                }

                if !(200..<300).contains(response.statusCode) {
                    if let fallback = self.fallbackRateWindow(from: response.body) {
                        return (fallback, nil, nil)
                    }
                    lastError = self.errorMessage(from: response.body)
                    break
                }

                guard let data = response.body.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = payload["models"] as? [String: Any]
                else {
                    lastError = "Invalid response"
                    continue
                }

                if let window = self.buildAntigravityWindows(models: models) {
                    return window
                }
                lastError = "No quota data"
            }
        }

        throw CLIProxyAPIQuotaError.apiFailure(lastError)
    }

    private static func buildAntigravityWindows(models: [String: Any]) -> (RateWindow?, RateWindow?, RateWindow?)? {
        let modelQuotas = self.antigravityModelQuotas(models: models)
        guard !modelQuotas.isEmpty else { return nil }
        let selected = self.selectAntigravityModels(modelQuotas)
        guard let primary = selected.first else { return nil }
        let primaryWindow = self.antigravityWindow(from: primary)
        let secondaryWindow = selected.count > 1 ? self.antigravityWindow(from: selected[1]) : nil
        let tertiaryWindow = selected.count > 2 ? self.antigravityWindow(from: selected[2]) : nil
        return (primaryWindow, secondaryWindow, tertiaryWindow)
    }

    private static func antigravityWindow(from quota: AntigravityModelQuota) -> RateWindow {
        RateWindow(
            usedPercent: 100 - quota.remainingPercent,
            windowMinutes: nil,
            resetsAt: quota.resetTime,
            resetDescription: quota.resetDescription)
    }

    private static func antigravityModelQuotas(models: [String: Any]) -> [AntigravityModelQuota] {
        var quotas: [AntigravityModelQuota] = []
        for (key, value) in models {
            guard let entry = value as? [String: Any] else { continue }
            let label = self.stringValue(entry["displayName"]) ?? self.stringValue(entry["display_name"]) ?? key
            let info = self.antigravityQuotaInfo(entry)
            let remainingFraction = info.remainingFraction
            let resetTime = info.resetTime
            let resetDescription = resetTime.map { UsageFormatter.resetDescription(from: $0) }
            let quota = AntigravityModelQuota(
                label: label,
                modelId: key,
                remainingFraction: remainingFraction,
                resetTime: resetTime,
                resetDescription: resetDescription)
            quotas.append(quota)
        }
        return quotas
    }

    private static func selectAntigravityModels(_ models: [AntigravityModelQuota]) -> [AntigravityModelQuota] {
        var ordered: [AntigravityModelQuota] = []
        if let claude = models.first(where: { self.isClaudeWithoutThinking($0.label) }) {
            ordered.append(claude)
        }
        if let pro = models.first(where: { self.isGeminiProLow($0.label) }),
           !ordered.contains(where: { $0.label == pro.label })
        {
            ordered.append(pro)
        }
        if let flash = models.first(where: { self.isGeminiFlash($0.label) }),
           !ordered.contains(where: { $0.label == flash.label })
        {
            ordered.append(flash)
        }
        if ordered.isEmpty {
            ordered.append(contentsOf: models.sorted(by: { $0.remainingPercent < $1.remainingPercent }))
        }
        return ordered
    }

    private static func isClaudeWithoutThinking(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("claude") && !lower.contains("thinking")
    }

    private static func isGeminiProLow(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("pro") && lower.contains("low")
    }

    private static func isGeminiFlash(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("gemini") && lower.contains("flash")
    }

    private static func antigravityQuotaInfo(_ entry: [String: Any]) -> (remainingFraction: Double?, resetTime: Date?) {
        let quotaInfo = (entry["quotaInfo"] as? [String: Any]) ?? (entry["quota_info"] as? [String: Any])
        let remaining = self.numberValue(quotaInfo?["remainingFraction"]) ??
            self.numberValue(quotaInfo?["remaining_fraction"]) ??
            self.numberValue(quotaInfo?["remaining"])
        let resetRaw = quotaInfo?["resetTime"] ?? quotaInfo?["reset_time"]
        let resetTime = (resetRaw as? String).flatMap { self.parseISODate($0) }
        return (remaining, resetTime)
    }

    private static func findAntigravityModel(models: [String: Any], identifier: String) -> [String: Any]? {
        if let entry = models[identifier] as? [String: Any] { return entry }
        let target = identifier.lowercased()
        for (_, value) in models {
            guard let entry = value as? [String: Any] else { continue }
            if let displayName = entry["displayName"] as? String,
               displayName.lowercased() == target
            {
                return entry
            }
        }
        return nil
    }

    private static func resolveAntigravityProjectID(
        authFile: CLIProxyAPIAuthFile,
        client: CLIProxyAPIManagementClient) async -> String
    {
        let fallback = self.antigravityDefaultProjectID
        let data = try? await client.downloadAuthFile(name: authFile.name)
        guard let data else { return fallback }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }

        if let projectID = self.stringValue(json["project_id"] ?? json["projectId"]) {
            return projectID
        }
        if let installed = json["installed"] as? [String: Any],
           let projectID = self.stringValue(installed["project_id"] ?? installed["projectId"])
        {
            return projectID
        }
        if let web = json["web"] as? [String: Any],
           let projectID = self.stringValue(web["project_id"] ?? web["projectId"])
        {
            return projectID
        }
        return fallback
    }

    private static func resolveGeminiCLIProjectID(authFile: CLIProxyAPIAuthFile) -> String? {
        let candidates = [authFile.account, authFile.label, authFile.email]
        for candidate in candidates {
            guard let candidate else { continue }
            if let projectID = self.extractProjectID(candidate) {
                return projectID
            }
        }
        return nil
    }

    private static func extractProjectID(_ value: String) -> String? {
        let pattern = #"\(([^()]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: range)
        guard let last = matches.last, let captureRange = Range(last.range(at: 1), in: value) else { return nil }
        let projectID = String(value[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return projectID.isEmpty ? nil : projectID
    }

    private static func resolveCodexAccountID(
        authFile: CLIProxyAPIAuthFile,
        client: CLIProxyAPIManagementClient) async -> String?
    {
        if let id = authFile.idToken?.chatgptAccountID, !id.isEmpty { return id }
        guard let data = try? await client.downloadAuthFile(name: authFile.name) else { return nil }
        return self.extractCodexClaims(from: data).accountID
    }

    private static func identitySnapshot(for authFile: CLIProxyAPIAuthFile) -> ProviderIdentitySnapshot? {
        let email = self.stringValue(authFile.email) ?? self.stringValue(authFile.label)
        let planType = authFile.idToken?.planType
        let loginMethod = planType.map { UsageFormatter.cleanPlanName($0) }
        let providerKey = self.providerKey(for: authFile)
        if email == nil && loginMethod == nil && providerKey == nil { return nil }
        return ProviderIdentitySnapshot(
            providerID: .cliproxyapi,
            accountEmail: email,
            accountOrganization: providerKey,
            loginMethod: loginMethod)
    }

    private static func providerKey(for authFile: CLIProxyAPIAuthFile) -> String? {
        let provider = authFile.normalizedProvider
        if provider.isEmpty { return nil }
        return provider
    }

    private static func extractCodexClaims(from data: Data) -> (accountID: String?, planType: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let idTokenRaw = json["id_token"] ?? (json["tokens"] as? [String: Any])?["id_token"]
        if let token = idTokenRaw as? [String: Any] {
            return (self.stringValue(token["chatgpt_account_id"]), self.stringValue(token["plan_type"]))
        }
        if let token = idTokenRaw as? String {
            if let payload = UsageFetcher.parseJWT(token) {
                let accountID = self.stringValue(payload["chatgpt_account_id"]) ??
                    self.stringValue(payload["chatgptAccountId"])
                let planType = self.stringValue(payload["plan_type"]) ??
                    self.stringValue(payload["chatgpt_plan_type"]) ??
                    self.stringValue(payload["planType"])
                return (accountID, planType)
            }
            if let parsed = try? JSONSerialization.jsonObject(with: Data(token.utf8)) as? [String: Any] {
                let accountID = self.stringValue(parsed["chatgpt_account_id"])
                let planType = self.stringValue(parsed["plan_type"]) ?? self.stringValue(parsed["chatgpt_plan_type"])
                return (accountID, planType)
            }
        }
        return (nil, nil)
    }

    private static func makeCodexWindow(
        window: CLIProxyAPICodexUsageWindow?,
        limitReached: Bool?,
        allowed: Bool?) -> RateWindow?
    {
        guard let window else { return nil }
        let usedPercentValue = self.numberValue(window.usedPercent) ?? self.numberValue(window.used_percent)
        let isLimitReached = limitReached == true || allowed == false
        let resolvedPercent = usedPercentValue ?? (isLimitReached ? 100 : 0)
        let windowSeconds = self.numberValue(window.limitWindowSeconds ?? window.limit_window_seconds)
        let windowMinutes = windowSeconds.map { Int($0 / 60.0) }
        let resetAtSeconds = self.numberValue(window.resetAt ?? window.reset_at)
        let resetAfter = self.numberValue(window.resetAfterSeconds ?? window.reset_after_seconds)
        let resetsAt = self.resetDate(resetAt: resetAtSeconds, resetAfter: resetAfter)
        return RateWindow(
            usedPercent: resolvedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    private static func resetDate(resetAt: Double?, resetAfter: Double?) -> Date? {
        if let resetAt, resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter, resetAfter > 0 {
            return Date().addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func resolveRemainingFraction(
        rawFraction: Double?,
        rawRemaining: Double?,
        resetTime: String?) -> Double?
    {
        if let rawFraction { return rawFraction }
        if let rawRemaining { return rawRemaining <= 0 ? 0 : nil }
        if resetTime != nil { return 0 }
        return nil
    }

    private static func percentUsed(fromRemaining remaining: Double) -> Double {
        let clamped = min(1, max(0, remaining))
        return min(100, max(0, (1 - clamped) * 100))
    }

    private static func geminiModelQuotas(from buckets: [CLIProxyAPIGeminiQuotaBucket]) -> [GeminiModelQuota] {
        var quotas: [GeminiModelQuota] = []
        for bucket in buckets {
            let modelID = bucket.modelId ?? bucket.modelID
            guard let modelID, !modelID.isEmpty, !self.isIgnoredGeminiModel(modelID) else { continue }
            let remainingFraction = self.resolveRemainingFraction(
                rawFraction: bucket.remainingFraction ?? bucket.remaining_fraction,
                rawRemaining: bucket.remainingAmount ?? bucket.remaining_amount,
                resetTime: bucket.resetTime ?? bucket.reset_time)
            guard let remainingFraction else { continue }
            let percentLeft = max(0, min(100, remainingFraction * 100))
            let resetTime = self.parseISODate(bucket.resetTime ?? bucket.reset_time)
            let resetDescription = resetTime.map { UsageFormatter.resetDescription(from: $0) }
            quotas.append(GeminiModelQuota(
                modelId: modelID,
                percentLeft: percentLeft,
                resetTime: resetTime,
                resetDescription: resetDescription))
        }
        return quotas
    }

    private static func numberValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return Double(trimmed)
        default:
            return nil
        }
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let raw = raw as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func isIgnoredGeminiModel(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return self.geminiIgnoredPrefixes.contains { lower.hasPrefix($0) }
    }

    private static func parseISODate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func earlierDate(_ current: Date?, _ next: Date?) -> Date? {
        switch (current, next) {
        case (nil, nil): return nil
        case let (value, nil): return value
        case let (nil, value): return value
        case let (current?, next?): return min(current, next)
        }
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func errorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let error = json["error"] as? [String: Any] {
            if let message = self.stringValue(error["message"]) { return message }
            if let message = self.stringValue(error["error"]) { return message }
        }
        if let message = self.stringValue(json["message"]) { return message }
        if let message = self.stringValue(json["error"]) { return message }
        return nil
    }

    private static func fallbackRateWindow(from body: String) -> RateWindow? {
        let message = self.errorMessage(from: body)
        guard let reset = self.resetFromErrorMessage(message ?? "") else { return nil }
        return RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: reset, resetDescription: nil)
    }

    private static func resetFromErrorMessage(_ message: String) -> Date? {
        let pattern = #"reset after (\d+)s"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let captureRange = Range(match.range(at: 1), in: message)
        else {
            return nil
        }
        let secondsString = String(message[captureRange])
        guard let seconds = Double(secondsString) else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    private static func isAntigravityUnknownFieldError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("unknown name") && normalized.contains("cannot find field")
    }
}

enum CLIProxyAPIQuotaError: LocalizedError, Sendable {
    case unsupportedProvider(String)
    case missingCodexAccountID
    case missingProjectID
    case invalidPayload
    case apiFailure(String?)
    case unavailable

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "CLIProxyAPI provider \(provider) is not supported for quota."
        case .missingCodexAccountID:
            return "CLIProxyAPI codex account ID is missing."
        case .missingProjectID:
            return "CLIProxyAPI project ID is missing."
        case .invalidPayload:
            return "CLIProxyAPI quota response is invalid."
        case let .apiFailure(message):
            if let message, !message.isEmpty { return message }
            return "CLIProxyAPI quota request failed."
        case .unavailable:
            return "CLIProxyAPI account is unavailable."
        }
    }
}

struct CLIProxyAPICodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: CLIProxyAPICodexRateLimitInfo?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case planTypeCamel = "planType"
        case rateLimit = "rate_limit"
        case rateLimitCamel = "rateLimit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .planTypeCamel)
        self.rateLimit = try container.decodeIfPresent(CLIProxyAPICodexRateLimitInfo.self, forKey: .rateLimit)
            ?? container.decodeIfPresent(CLIProxyAPICodexRateLimitInfo.self, forKey: .rateLimitCamel)
    }
}

struct CLIProxyAPICodexRateLimitInfo: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CLIProxyAPICodexUsageWindow?
    let secondaryWindow: CLIProxyAPICodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case limitReachedCamel = "limitReached"
        case primaryWindow = "primary_window"
        case primaryWindowCamel = "primaryWindow"
        case secondaryWindow = "secondary_window"
        case secondaryWindowCamel = "secondaryWindow"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed)
        self.limitReached = try container.decodeIfPresent(Bool.self, forKey: .limitReached)
            ?? container.decodeIfPresent(Bool.self, forKey: .limitReachedCamel)
        self.primaryWindow = try container.decodeIfPresent(CLIProxyAPICodexUsageWindow.self, forKey: .primaryWindow)
            ?? container.decodeIfPresent(CLIProxyAPICodexUsageWindow.self, forKey: .primaryWindowCamel)
        self.secondaryWindow = try container.decodeIfPresent(CLIProxyAPICodexUsageWindow.self, forKey: .secondaryWindow)
            ?? container.decodeIfPresent(CLIProxyAPICodexUsageWindow.self, forKey: .secondaryWindowCamel)
    }
}

struct CLIProxyAPICodexUsageWindow: Decodable {
    let usedPercent: Double?
    let used_percent: Double?
    let limitWindowSeconds: Double?
    let limit_window_seconds: Double?
    let resetAfterSeconds: Double?
    let reset_after_seconds: Double?
    let resetAt: Double?
    let reset_at: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "usedPercent"
        case used_percent = "used_percent"
        case limitWindowSeconds = "limitWindowSeconds"
        case limit_window_seconds = "limit_window_seconds"
        case resetAfterSeconds = "resetAfterSeconds"
        case reset_after_seconds = "reset_after_seconds"
        case resetAt = "resetAt"
        case reset_at = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = container.decodeLossyDouble(forKey: .usedPercent)
        self.used_percent = container.decodeLossyDouble(forKey: .used_percent)
        self.limitWindowSeconds = container.decodeLossyDouble(forKey: .limitWindowSeconds)
        self.limit_window_seconds = container.decodeLossyDouble(forKey: .limit_window_seconds)
        self.resetAfterSeconds = container.decodeLossyDouble(forKey: .resetAfterSeconds)
        self.reset_after_seconds = container.decodeLossyDouble(forKey: .reset_after_seconds)
        self.resetAt = container.decodeLossyDouble(forKey: .resetAt)
        self.reset_at = container.decodeLossyDouble(forKey: .reset_at)
    }
}

struct CLIProxyAPIGeminiQuotaPayload: Decodable {
    let buckets: [CLIProxyAPIGeminiQuotaBucket]?
}

struct CLIProxyAPIGeminiQuotaBucket: Decodable {
    let modelId: String?
    let modelID: String?
    let tokenType: String?
    let remainingFraction: Double?
    let remaining_fraction: Double?
    let remainingAmount: Double?
    let remaining_amount: Double?
    let resetTime: String?
    let reset_time: String?

    enum CodingKeys: String, CodingKey {
        case modelId
        case modelID = "model_id"
        case tokenType
        case remainingFraction
        case remaining_fraction
        case remainingAmount
        case remaining_amount
        case resetTime
        case reset_time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        self.remainingFraction = container.decodeLossyDouble(forKey: .remainingFraction)
        self.remaining_fraction = container.decodeLossyDouble(forKey: .remaining_fraction)
        self.remainingAmount = container.decodeLossyDouble(forKey: .remainingAmount)
        self.remaining_amount = container.decodeLossyDouble(forKey: .remaining_amount)
        self.resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
        self.reset_time = try container.decodeIfPresent(String.self, forKey: .reset_time)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyDouble(forKey key: Key) -> Double? {
        if let value = try? self.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? self.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Double(trimmed)
        }
        if let value = try? self.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? self.decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}
