import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GeminiModelQuota: Sendable {
    public let modelId: String
    public let percentLeft: Double
    public let resetTime: Date?
    public let resetDescription: String?
}

public struct GeminiStatusSnapshot: Sendable {
    public let modelQuotas: [GeminiModelQuota]
    public let rawText: String
    public let accountEmail: String?
    public let accountPlan: String?

    // Convenience: lowest quota across all models (for icon display)
    public var lowestPercentLeft: Double? {
        self.modelQuotas.min(by: { $0.percentLeft < $1.percentLeft })?.percentLeft
    }

    /// Legacy compatibility
    public var dailyPercentLeft: Double? {
        self.lowestPercentLeft
    }

    public var resetDescription: String? {
        self.modelQuotas.min(by: { $0.percentLeft < $1.percentLeft })?.resetDescription
    }

    /// Converts Gemini quotas to a unified UsageSnapshot.
    /// Groups quotas by tier: Pro (24h window) as primary, Flash (24h window) as secondary.
    public func toUsageSnapshot() -> UsageSnapshot {
        let lower = self.modelQuotas.map { ($0.modelId.lowercased(), $0) }
        let flashQuotas = lower.filter { $0.0.contains("flash") }.map(\.1)
        let proQuotas = lower.filter { $0.0.contains("pro") }.map(\.1)

        let flashMin = flashQuotas.min(by: { $0.percentLeft < $1.percentLeft })
        let proMin = proQuotas.min(by: { $0.percentLeft < $1.percentLeft })

        let primary = RateWindow(
            usedPercent: proMin.map { 100 - $0.percentLeft } ?? 0,
            windowMinutes: 1440,
            resetsAt: proMin?.resetTime,
            resetDescription: proMin?.resetDescription)

        let secondary: RateWindow? = flashMin.map {
            RateWindow(
                usedPercent: 100 - $0.percentLeft,
                windowMinutes: 1440,
                resetsAt: $0.resetTime,
                resetDescription: $0.resetDescription)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .gemini,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.accountPlan)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: identity)
    }
}

public enum GeminiStatusProbeError: LocalizedError, Sendable, Equatable {
    case geminiNotInstalled
    case notLoggedIn
    case unsupportedAuthType(String)
    case parseFailed(String)
    case timedOut
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .geminiNotInstalled:
            "Gemini CLI is not installed or not on PATH."
        case .notLoggedIn:
            "Not logged in to Gemini. Run 'gemini' in Terminal to authenticate."
        case let .unsupportedAuthType(authType):
            "Gemini \(authType) auth not supported. Use Google account (OAuth) instead."
        case let .parseFailed(msg):
            "Could not parse Gemini usage: \(msg)"
        case .timedOut:
            "Gemini quota API request timed out."
        case let .apiError(msg):
            "Gemini API error: \(msg)"
        }
    }
}

public enum GeminiAuthType: String, Sendable {
    case oauthPersonal = "oauth-personal"
    case apiKey = "api-key"
    case vertexAI = "vertex-ai"
    case unknown
}

/// User tier IDs returned from the Cloud Code Private API (loadCodeAssist).
/// Maps to: google3/cloud/developer_experience/cloudcode/pa/service/usertier.go
public enum GeminiUserTierId: String, Sendable {
    case free = "free-tier"
    case legacy = "legacy-tier"
    case standard = "standard-tier"
}

public struct GeminiStatusProbe: Sendable {
    public var timeout: TimeInterval = 10.0
    public var homeDirectory: String
    public var dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private static let log = CodexBarLog.logger(LogCategories.geminiProbe)
    private static let quotaEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let projectsEndpoint = "https://cloudresourcemanager.googleapis.com/v1/projects"
    private static let credentialsPath = "/.gemini/oauth_creds.json"
    private static let settingsPath = "/.gemini/settings.json"
    private static let tokenRefreshEndpoint = "https://oauth2.googleapis.com/token"

    public init(
        timeout: TimeInterval = 10.0,
        homeDirectory: String = NSHomeDirectory(),
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        })
    {
        self.timeout = timeout
        self.homeDirectory = homeDirectory
        self.dataLoader = dataLoader
    }

    /// Reads the current Gemini auth type from settings.json
    public static func currentAuthType(homeDirectory: String = NSHomeDirectory()) -> GeminiAuthType {
        let settingsURL = URL(fileURLWithPath: homeDirectory + Self.settingsPath)

        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selectedType = auth["selectedType"] as? String
        else {
            return .unknown
        }

        return GeminiAuthType(rawValue: selectedType) ?? .unknown
    }

    public func fetch() async throws -> GeminiStatusSnapshot {
        // Block explicitly unsupported auth types; allow unknown to try OAuth creds
        let authType = Self.currentAuthType(homeDirectory: self.homeDirectory)
        switch authType {
        case .apiKey:
            throw GeminiStatusProbeError.unsupportedAuthType("API key")
        case .vertexAI:
            throw GeminiStatusProbeError.unsupportedAuthType("Vertex AI")
        case .oauthPersonal, .unknown:
            break
        }

        let snap = try await Self.fetchViaAPI(
            timeout: self.timeout,
            homeDirectory: self.homeDirectory,
            dataLoader: self.dataLoader)

        Self.log.info("Gemini API fetch ok", metadata: [
            "dailyPercentLeft": "\(snap.dailyPercentLeft ?? -1)",
        ])
        return snap
    }

    // MARK: - Direct API approach

    private static func fetchViaAPI(
        timeout: TimeInterval,
        homeDirectory: String,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> GeminiStatusSnapshot
    {
        let creds = try Self.loadCredentials(homeDirectory: homeDirectory)

        let expiryStr = creds.expiryDate.map { "\($0)" } ?? "nil"
        let hasRefresh = creds.refreshToken != nil
        Self.log.debug("Token check", metadata: [
            "expiry": expiryStr,
            "hasRefresh": hasRefresh ? "1" : "0",
            "now": "\(Date())",
        ])

        guard let storedAccessToken = creds.accessToken, !storedAccessToken.isEmpty else {
            Self.log.error("No access token found")
            throw GeminiStatusProbeError.notLoggedIn
        }

        var accessToken = storedAccessToken
        if let expiry = creds.expiryDate, expiry < Date() {
            Self.log.info("Token expired; attempting refresh", metadata: [
                "expiry": "\(expiry)",
            ])

            guard let refreshToken = creds.refreshToken else {
                Self.log.error("No refresh token available")
                throw GeminiStatusProbeError.notLoggedIn
            }

            accessToken = try await Self.refreshAccessToken(
                refreshToken: refreshToken,
                timeout: timeout,
                homeDirectory: homeDirectory,
                dataLoader: dataLoader)
        }

        // Extract account info from JWT
        let claims = Self.extractClaimsFromToken(creds.idToken)

        // Load Code Assist status to get project ID and tier (aligned with CLI setupUser logic)
        let caStatus = await Self.loadCodeAssistStatus(
            accessToken: accessToken,
            timeout: timeout,
            dataLoader: dataLoader)

        // Determine the project ID to use for quota fetching.
        // Priority:
        // 1. Project ID returned by loadCodeAssist (e.g. managed project for free tier)
        // 2. Discovered project ID from cloud resource manager (e.g. user's own project)
        var projectId = caStatus.projectId
        if projectId == nil {
            projectId = try? await Self.discoverGeminiProjectId(
                accessToken: accessToken,
                timeout: timeout,
                dataLoader: dataLoader)
        }

        guard let url = URL(string: Self.quotaEndpoint) else {
            throw GeminiStatusProbeError.apiError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Include project ID for accurate quota
        if let projectId {
            request.httpBody = Data("{\"project\": \"\(projectId)\"}".utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }
        request.timeoutInterval = timeout

        let (data, response) = try await dataLoader(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiStatusProbeError.apiError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            throw GeminiStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw GeminiStatusProbeError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let snapshot = try Self.parseAPIResponse(data, email: claims.email)

        // Plan display strings with tier mapping:
        // - standard-tier: Paid subscription (AI Pro, AI Ultra, Code Assist
        //   Standard/Enterprise, Developer Program Premium)
        // - free-tier + hd claim: Workspace account (Gemini included free since Jan 2025)
        // - free-tier: Personal free account (1000 req/day limit)
        // - legacy-tier: Unknown legacy/grandfathered tier
        // - nil (API failed): Leave blank (no display)
        let plan: String? = switch (caStatus.tier, claims.hostedDomain) {
        case (.standard, _):
            "Paid"
        case let (.free, .some(domain)):
            { Self.log.info("Workspace account detected", metadata: ["domain": domain]); return "Workspace" }()
        case (.free, .none):
            { Self.log.info("Personal free account"); return "Free" }()
        case (.legacy, _):
            "Legacy"
        case (.none, _):
            { Self.log.info("Tier detection failed, leaving plan blank"); return nil }()
        }

        return GeminiStatusSnapshot(
            modelQuotas: snapshot.modelQuotas,
            rawText: snapshot.rawText,
            accountEmail: snapshot.accountEmail,
            accountPlan: plan)
    }

    private static func discoverGeminiProjectId(
        accessToken: String,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> String?
    {
        guard let url = URL(string: projectsEndpoint) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await dataLoader(request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]]
        else {
            return nil
        }

        // Look for Gemini API project (has "generative-language" label or "gen-lang-client" prefix)
        for project in projects {
            guard let projectId = project["projectId"] as? String else { continue }

            // Check for gen-lang-client prefix (Gemini CLI projects)
            if projectId.hasPrefix("gen-lang-client") {
                return projectId
            }

            // Check for generative-language label
            if let labels = project["labels"] as? [String: String],
               labels["generative-language"] != nil
            {
                return projectId
            }
        }

        return nil
    }

    private struct CodeAssistStatus: Sendable {
        let tier: GeminiUserTierId?
        let projectId: String?

        static let empty = CodeAssistStatus(tier: nil, projectId: nil)
    }

    private static func loadCodeAssistStatus(
        accessToken: String,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async -> CodeAssistStatus
    {
        guard let url = URL(string: loadCodeAssistEndpoint) else {
            self.log.warning("loadCodeAssist: invalid endpoint URL")
            return .empty
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(request)
        } catch {
            Self.log.warning("loadCodeAssist: request failed", metadata: ["error": "\(error)"])
            return .empty
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.log.warning("loadCodeAssist: invalid response type")
            return .empty
        }

        guard httpResponse.statusCode == 200 else {
            Self.log.warning("loadCodeAssist: HTTP error", metadata: [
                "statusCode": "\(httpResponse.statusCode)",
                "body": String(data: data, encoding: .utf8) ?? "<binary>",
            ])
            return .empty
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.log.warning("loadCodeAssist: failed to parse JSON", metadata: [
                "body": String(data: data, encoding: .utf8) ?? "<binary>",
            ])
            return .empty
        }

        let rawProjectId: String? = {
            if let project = json["cloudaicompanionProject"] as? String {
                return project
            }
            if let project = json["cloudaicompanionProject"] as? [String: Any] {
                if let projectId = project["id"] as? String {
                    return projectId
                }
                if let projectId = project["projectId"] as? String {
                    return projectId
                }
            }
            return nil
        }()
        let trimmedProjectId = rawProjectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectId = trimmedProjectId?.isEmpty == true ? nil : trimmedProjectId
        if let projectId {
            Self.log.info("loadCodeAssist: project detected", metadata: ["projectId": projectId])
        }

        let tierId = (json["currentTier"] as? [String: Any])?["id"] as? String
        guard let tierId else {
            Self.log.warning("loadCodeAssist: no currentTier.id in response", metadata: [
                "json": "\(json)",
            ])
            return CodeAssistStatus(tier: nil, projectId: projectId)
        }

        guard let tier = GeminiUserTierId(rawValue: tierId) else {
            Self.log.warning("loadCodeAssist: unknown tier ID", metadata: ["tierId": tierId])
            return CodeAssistStatus(tier: nil, projectId: projectId)
        }

        Self.log.info("loadCodeAssist: success", metadata: ["tier": tierId, "projectId": projectId ?? "nil"])
        return CodeAssistStatus(tier: tier, projectId: projectId)
    }

    private struct OAuthCredentials {
        let accessToken: String?
        let idToken: String?
        let refreshToken: String?
        let expiryDate: Date?
    }

    private struct OAuthClientCredentials {
        let clientId: String
        let clientSecret: String
    }

    private static func extractOAuthCredentials() -> OAuthClientCredentials? {
        let env = ProcessInfo.processInfo.environment

        // Find the gemini binary
        guard let geminiPath = BinaryLocator.resolveGeminiBinary(
            env: env,
            loginPATH: LoginShellPathCache.shared.current)
            ?? TTYCommandRunner.which("gemini")
        else {
            return nil
        }

        // Resolve symlinks to find the actual installation
        let fm = FileManager.default
        var realPath = geminiPath
        if let resolved = try? fm.destinationOfSymbolicLink(atPath: geminiPath) {
            if resolved.hasPrefix("/") {
                realPath = resolved
            } else {
                realPath = (geminiPath as NSString).deletingLastPathComponent + "/" + resolved
            }
        }

        // Navigate from bin/gemini to the oauth2.js file
        // Homebrew path: .../libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js
        // Bun/npm path: .../node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js (sibling package)
        let binDir = (realPath as NSString).deletingLastPathComponent
        let baseDir = (binDir as NSString).deletingLastPathComponent

        let oauthSubpath =
            "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        let nixShareSubpath =
            "share/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        let oauthFile = "dist/src/code_assist/oauth2.js"
        let possiblePaths = [
            // Homebrew nested structure
            "\(baseDir)/libexec/lib/\(oauthSubpath)",
            "\(baseDir)/lib/\(oauthSubpath)",
            // Nix package layout
            "\(baseDir)/\(nixShareSubpath)",
            // Bun/npm sibling structure: gemini-cli-core is a sibling to gemini-cli
            "\(baseDir)/../gemini-cli-core/\(oauthFile)",
            // npm nested inside gemini-cli
            "\(baseDir)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]

        for path in possiblePaths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return self.parseOAuthCredentials(from: content)
            }
        }

        return nil
    }

    private static func parseOAuthCredentials(from content: String) -> OAuthClientCredentials? {
        // Match: const OAUTH_CLIENT_ID = '...';
        let clientIdPattern = #"OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#
        let secretPattern = #"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#

        guard let clientIdRegex = try? NSRegularExpression(pattern: clientIdPattern),
              let secretRegex = try? NSRegularExpression(pattern: secretPattern)
        else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)

        guard let clientIdMatch = clientIdRegex.firstMatch(in: content, range: range),
              let clientIdRange = Range(clientIdMatch.range(at: 1), in: content),
              let secretMatch = secretRegex.firstMatch(in: content, range: range),
              let secretRange = Range(secretMatch.range(at: 1), in: content)
        else {
            return nil
        }

        let clientId = String(content[clientIdRange])
        let clientSecret = String(content[secretRange])

        return OAuthClientCredentials(clientId: clientId, clientSecret: clientSecret)
    }

    private static func refreshAccessToken(
        refreshToken: String,
        timeout: TimeInterval,
        homeDirectory: String,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> String
    {
        guard let url = URL(string: tokenRefreshEndpoint) else {
            throw GeminiStatusProbeError.apiError("Invalid token refresh URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        guard let oauthCreds = Self.extractOAuthCredentials() else {
            Self.log.error("Could not extract OAuth credentials from Gemini CLI")
            throw GeminiStatusProbeError.apiError("Could not find Gemini CLI OAuth configuration")
        }

        let body = [
            "client_id=\(oauthCreds.clientId)",
            "client_secret=\(oauthCreds.clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await dataLoader(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiStatusProbeError.apiError("Invalid refresh response")
        }

        guard httpResponse.statusCode == 200 else {
            Self.log.error("Token refresh failed", metadata: [
                "statusCode": "\(httpResponse.statusCode)",
            ])
            throw GeminiStatusProbeError.notLoggedIn
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String
        else {
            throw GeminiStatusProbeError.parseFailed("Could not parse refresh response")
        }

        // Update stored credentials with new token
        try Self.updateStoredCredentials(json, homeDirectory: homeDirectory)

        Self.log.info("Token refreshed successfully")
        return newAccessToken
    }

    private static func updateStoredCredentials(_ refreshResponse: [String: Any], homeDirectory: String) throws {
        let credsURL = URL(fileURLWithPath: homeDirectory + Self.credentialsPath)

        guard let existingCreds = try? Data(contentsOf: credsURL),
              var json = try? JSONSerialization.jsonObject(with: existingCreds) as? [String: Any]
        else {
            return
        }

        // Update with new values from refresh response
        if let accessToken = refreshResponse["access_token"] {
            json["access_token"] = accessToken
        }
        if let expiresIn = refreshResponse["expires_in"] as? Double {
            json["expiry_date"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        if let idToken = refreshResponse["id_token"] {
            json["id_token"] = idToken
        }

        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try updatedData.write(to: credsURL, options: .atomic)
    }

    private static func loadCredentials(homeDirectory: String) throws -> OAuthCredentials {
        let credsURL = URL(fileURLWithPath: homeDirectory + Self.credentialsPath)

        guard FileManager.default.fileExists(atPath: credsURL.path) else {
            throw GeminiStatusProbeError.notLoggedIn
        }

        let data = try Data(contentsOf: credsURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiStatusProbeError.parseFailed("Invalid credentials file")
        }

        let accessToken = json["access_token"] as? String
        let idToken = json["id_token"] as? String
        let refreshToken = json["refresh_token"] as? String

        var expiryDate: Date?
        if let expiryMs = json["expiry_date"] as? Double {
            expiryDate = Date(timeIntervalSince1970: expiryMs / 1000)
        }

        return OAuthCredentials(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            expiryDate: expiryDate)
    }

    private struct TokenClaims {
        let email: String?
        let hostedDomain: String?
    }

    private static func extractClaimsFromToken(_ idToken: String?) -> TokenClaims {
        guard let token = idToken else { return TokenClaims(email: nil, hostedDomain: nil) }

        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return TokenClaims(email: nil, hostedDomain: nil) }

        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }

        return TokenClaims(
            email: json["email"] as? String,
            hostedDomain: json["hd"] as? String)
    }

    private static func extractEmailFromToken(_ idToken: String?) -> String? {
        self.extractClaimsFromToken(idToken).email
    }

    private struct QuotaBucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelId: String?
        let tokenType: String?
    }

    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private static func parseAPIResponse(_ data: Data, email: String?) throws -> GeminiStatusSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(QuotaResponse.self, from: data)

        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw GeminiStatusProbeError.parseFailed("No quota buckets in response")
        }

        // Group quotas by model, keeping lowest per model (input tokens usually)
        var modelQuotaMap: [String: (fraction: Double, resetString: String?)] = [:]

        for bucket in buckets {
            guard let modelId = bucket.modelId, let fraction = bucket.remainingFraction else { continue }

            if let existing = modelQuotaMap[modelId] {
                if fraction < existing.fraction {
                    modelQuotaMap[modelId] = (fraction, bucket.resetTime)
                }
            } else {
                modelQuotaMap[modelId] = (fraction, bucket.resetTime)
            }
        }

        // Convert to sorted array (by model name for consistent ordering)
        let quotas = modelQuotaMap
            .sorted { $0.key < $1.key }
            .map { modelId, info in
                let resetDate = info.resetString.flatMap { Self.parseResetTime($0) }
                return GeminiModelQuota(
                    modelId: modelId,
                    percentLeft: info.fraction * 100,
                    resetTime: resetDate,
                    resetDescription: info.resetString.flatMap { Self.formatResetTime($0) })
            }

        let rawText = String(data: data, encoding: .utf8) ?? ""

        return GeminiStatusSnapshot(
            modelQuotas: quotas,
            rawText: rawText,
            accountEmail: email,
            accountPlan: nil)
    }

    private static func parseResetTime(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: isoString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    private static func formatResetTime(_ isoString: String) -> String {
        guard let resetDate = parseResetTime(isoString) else {
            return "Resets soon"
        }

        let now = Date()
        let interval = resetDate.timeIntervalSince(now)

        if interval <= 0 {
            return "Resets soon"
        }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    // MARK: - Legacy CLI parsing (kept for fallback)

    public static func parse(text: String) throws -> GeminiStatusSnapshot {
        let clean = TextParsing.stripANSICodes(text)
        guard !clean.isEmpty else { throw GeminiStatusProbeError.timedOut }

        let quotas = Self.parseModelUsageTable(clean)

        if quotas.isEmpty {
            if clean.contains("Login with Google") || clean.contains("Use Gemini API key") {
                throw GeminiStatusProbeError.notLoggedIn
            }
            if clean.contains("Waiting for auth"), !clean.contains("Usage") {
                throw GeminiStatusProbeError.notLoggedIn
            }
            throw GeminiStatusProbeError.parseFailed("No usage data found in /stats output")
        }

        return GeminiStatusSnapshot(
            modelQuotas: quotas,
            rawText: text,
            accountEmail: nil,
            accountPlan: nil)
    }

    private static func parseModelUsageTable(_ text: String) -> [GeminiModelQuota] {
        let lines = text.components(separatedBy: .newlines)
        var quotas: [GeminiModelQuota] = []

        let pattern = #"(gemini[-\w.]+)\s+[\d-]+\s+([0-9]+(?:\.[0-9]+)?)\s*%\s*\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        for line in lines {
            let cleanLine = line.replacingOccurrences(of: "│", with: " ")
            let range = NSRange(cleanLine.startIndex..<cleanLine.endIndex, in: cleanLine)
            guard let match = regex.firstMatch(in: cleanLine, options: [], range: range),
                  match.numberOfRanges >= 4 else { continue }

            guard let modelRange = Range(match.range(at: 1), in: cleanLine),
                  let pctRange = Range(match.range(at: 2), in: cleanLine),
                  let pct = Double(cleanLine[pctRange])
            else { continue }

            let modelId = String(cleanLine[modelRange])
            var resetDesc: String?
            if let resetRange = Range(match.range(at: 3), in: cleanLine) {
                resetDesc = String(cleanLine[resetRange]).trimmingCharacters(in: .whitespaces)
            }

            quotas.append(GeminiModelQuota(
                modelId: modelId,
                percentLeft: pct,
                resetTime: nil,
                resetDescription: resetDesc))
        }

        return quotas
    }
}
