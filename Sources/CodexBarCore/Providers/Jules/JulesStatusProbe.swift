import Foundation

public struct JulesStatusSnapshot: Sendable {
    public let activeSessions: Int
    public let totalLimit: Int
    public let isAuthenticated: Bool
    public let rawText: String
    public let accountEmail: String?
    public let accountPlan: String?

    public init(
        activeSessions: Int,
        totalLimit: Int = 100,
        isAuthenticated: Bool,
        rawText: String,
        accountEmail: String? = nil,
        accountPlan: String? = nil)
    {
        self.activeSessions = activeSessions
        self.totalLimit = totalLimit
        self.isAuthenticated = isAuthenticated
        self.rawText = rawText
        self.accountEmail = accountEmail
        self.accountPlan = accountPlan
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let limit = max(1, self.totalLimit)
        let usedPercent = (Double(self.activeSessions) / Double(limit)) * 100.0

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 24 * 60, // 24h rolling window
            resetsAt: nil,
            resetDescription: "\(self.activeSessions)/\(limit) (24h rolling)")

        let identity = ProviderIdentitySnapshot(
            providerID: .jules,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.accountPlan)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            openRouterUsage: nil,
            cursorRequests: nil,
            updatedAt: Date(),
            identity: identity)
    }
}

public enum JulesStatusProbeError: LocalizedError, Sendable, Equatable {
    case julesNotInstalled
    case notLoggedIn
    case commandFailed(String)
    case timedOut
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .julesNotInstalled:
            "Jules CLI is not installed or not on PATH."
        case .notLoggedIn:
            "Not logged in to Jules. Run 'jules login' in Terminal to authenticate."
        case let .commandFailed(msg):
            "Jules CLI error: \(msg)"
        case .timedOut:
            "Jules CLI request timed out."
        case let .apiError(msg):
            "Jules API error: \(msg)"
        }
    }
}

public struct JulesStatusProbe: Sendable {
    public var timeout: TimeInterval = 10.0
    private static let log = CodexBarLog.logger(LogCategories.providers)
    
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let geminiCredentialsPath = "/.gemini/oauth_creds.json"

    public init(timeout: TimeInterval = 10.0) {
        self.timeout = timeout
    }

    public static func parse(text: String, email: String? = nil, plan: String? = nil) throws -> JulesStatusSnapshot {
        if text.contains("did you forget to login") || text.contains("jules login") {
            throw JulesStatusProbeError.notLoggedIn
        }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if text.contains("No sessions found") {
            return JulesStatusSnapshot(
                activeSessions: 0,
                totalLimit: 100,
                isAuthenticated: true,
                rawText: text,
                accountEmail: email,
                accountPlan: plan)
        }

        var activeSessions = 0
        if let first = lines.first, first.contains("ID") && first.contains("Description") {
            activeSessions = max(0, lines.count - 1)
        } else {
            activeSessions = lines.count
        }

        return JulesStatusSnapshot(
            activeSessions: activeSessions,
            totalLimit: 100,
            isAuthenticated: true,
            rawText: text,
            accountEmail: email,
            accountPlan: plan)
    }

    public func fetch() async throws -> JulesStatusSnapshot {
        guard TTYCommandRunner.which("jules") != nil else {
            throw JulesStatusProbeError.julesNotInstalled
        }

        // Try identity fetch leveraging Gemini credentials
        let (email, plan) = await self.fetchIdentityFromCLIState()

        let binary = TTYCommandRunner.which("jules") ?? "jules"
        
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                binary: binary,
                arguments: ["remote", "list", "--session"],
                environment: TTYCommandRunner.enrichedEnvironment(),
                timeout: self.timeout,
                label: "jules-status")
        } catch let SubprocessRunnerError.nonZeroExit(_, stderr) {
            // Even if the command failed, it might contain the login error message.
            return try Self.parse(text: stderr, email: email, plan: plan)
        } catch {
            throw error
        }

        return try Self.parse(text: result.stdout + result.stderr, email: email, plan: plan)
    }

    // MARK: - Identity Resolution

    private struct OAuthCredentials {
        let accessToken: String?
        let idToken: String?
    }

    /// Fetches identity info from shared CLI state (Gemini credentials).
    private func fetchIdentityFromCLIState() async -> (email: String?, plan: String?) {
        guard let creds = try? loadSharedCredentials() else {
            Self.log.info("No shared credentials found for Jules identity")
            return (nil, nil)
        }
        
        let email = extractEmailFromToken(creds.idToken)
        
        var plan: String? = nil
        if let accessToken = creds.accessToken {
            plan = await fetchTier(accessToken: accessToken)
        }
        
        return (email, plan)
    }

    private func loadSharedCredentials() throws -> OAuthCredentials {
        let home = NSHomeDirectory()
        let credsURL = URL(fileURLWithPath: home + Self.geminiCredentialsPath)

        guard FileManager.default.fileExists(atPath: credsURL.path) else {
            throw JulesStatusProbeError.notLoggedIn
        }

        let data = try Data(contentsOf: credsURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JulesStatusProbeError.apiError("Invalid credentials file")
        }

        return OAuthCredentials(
            accessToken: json["access_token"] as? String,
            idToken: json["id_token"] as? String)
    }

    private func extractEmailFromToken(_ idToken: String?) -> String? {
        guard let token = idToken else { return nil }

        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

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
            return nil
        }

        return json["email"] as? String
    }

    private func fetchTier(accessToken: String) async -> String? {
        guard let url = URL(string: Self.loadCodeAssistEndpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)
        request.timeoutInterval = self.timeout
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let currentTier = json["currentTier"] as? [String: Any],
               let tierId = currentTier["id"] as? String {
                switch tierId {
                case "standard-tier": return "Paid"
                case "free-tier": return "Free"
                case "legacy-tier": return "Legacy"
                default: return nil
                }
            }
        } catch {
            Self.log.warning("Jules identity fetch failed", metadata: ["error": "\(error)"])
        }
        return nil
    }
}
