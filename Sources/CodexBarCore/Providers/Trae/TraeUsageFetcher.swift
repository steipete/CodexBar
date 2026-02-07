import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

public enum TraeUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case invalidCredentials
    case parseFailed(String)
    case networkError(String)
    case noAuthToken

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Trae. Please log in via trae.ai."
        case .invalidCredentials:
            "Trae session expired. Please log in again."
        case let .parseFailed(message):
            "Could not parse Trae usage: \(message)"
        case let .networkError(message):
            "Trae request failed: \(message)"
        case .noAuthToken:
            "No Trae authentication found. Please log in to trae.ai in your browser."
        }
    }
}

#if os(macOS)
private let traeCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.trae]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum TraeAuthImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["trae.ai", "www.trae.ai", ".trae.ai", ".byteoversea.com"]

    public struct AuthInfo: Sendable {
        public let jwtToken: String
        public let sourceLabel: String

        public init(jwtToken: String, sourceLabel: String) {
            self.jwtToken = jwtToken
            self.sourceLabel = sourceLabel
        }
    }

    public static func importAuth(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> AuthInfo
    {
        let log: (String) -> Void = { msg in logger?("[trae-auth] \(msg)") }

        let installed = traeCookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installed {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    
                    // Look for X-Cloudide-Session cookie which contains the JWT
                    for cookie in cookies {
                        if cookie.name == "X-Cloudide-Session" {
                            log("Found Trae session cookie in \(source.label)")
                            // The JWT is the cookie value itself
                            return AuthInfo(
                                jwtToken: "Cloud-IDE-JWT \(cookie.value)",
                                sourceLabel: source.label)
                        }
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) import failed: \(error.localizedDescription)")
            }
        }

        throw TraeUsageError.noAuthToken
    }
}
#endif

public struct TraeUsageFetcher: Sendable {
    private static let apiURL = URL(string: "https://api-sg-central.trae.ai/trae/api/v1/pay/user_current_entitlement_list")!
    @MainActor private static var recentDumps: [String] = []

    public let browserDetection: BrowserDetection

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    public func fetch(
        jwtOverride: String? = nil,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> TraeUsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[trae] \(msg)") }
        
        // Resolve JWT token (from override or browser)
        let jwtToken = try await self.resolveJWTToken(override: jwtOverride, logger: log)
        log("[trae] Using JWT authentication: \(jwtToken.prefix(50))...")

        let (data, response) = try await self.fetchWithJWT(jwtToken: jwtToken)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TraeUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw TraeUsageError.invalidCredentials
            }
            throw TraeUsageError.networkError("HTTP \(httpResponse.statusCode)")
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw TraeUsageError.parseFailed("Response was not UTF-8")
        }

        do {
            return try TraeUsageParser.parse(json: jsonString, now: now)
        } catch {
            logger?("[trae] Parse failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func fetchWithJWT(jwtToken: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "GET"
        request.setValue(jwtToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.trae.ai", forHTTPHeaderField: "Referer")
        request.setValue("https://www.trae.ai", forHTTPHeaderField: "Origin")

        return try await URLSession.shared.data(for: request)
    }

    private func resolveJWTToken(
        override: String?,
        logger: ((String) -> Void)?) async throws -> String
    {
        // If override provided, use it
        if let override = override, !override.isEmpty {
            logger?("[trae] Using manual JWT token")
            // Ensure it has the Cloud-IDE-JWT prefix
            if override.hasPrefix("Cloud-IDE-JWT") {
                return override
            } else {
                return "Cloud-IDE-JWT \(override)"
            }
        }
        
        #if os(macOS)
        // Try to auto-import from browser
        do {
            let auth = try TraeAuthImporter.importAuth(browserDetection: self.browserDetection, logger: logger)
            logger?("[trae] Using JWT from \(auth.sourceLabel)")
            return auth.jwtToken
        } catch {
            logger?("[trae] Auto-import failed: \(error.localizedDescription)")
        }
        #endif
        
        throw TraeUsageError.noAuthToken
    }

    public func debugRawProbe(jwtOverride: String? = nil) async -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("=== Trae Debug Probe @ \(stamp) ===")
        lines.append("")

        do {
            let jwtToken = try await self.resolveJWTToken(
                override: jwtOverride,
                logger: { msg in lines.append("[auth] \(msg)") })
            lines.append("JWT Token: \(jwtToken.prefix(50))...")

            let (data, response) = try await self.fetchWithJWT(jwtToken: jwtToken)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TraeUsageError.networkError("Invalid response")
            }

            lines.append("")
            lines.append("Fetch Response")
            lines.append("Status: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                if let jsonString = String(data: data, encoding: .utf8) {
                    do {
                        let snapshot = try TraeUsageParser.parse(json: jsonString, now: Date())
                        lines.append("")
                        lines.append("Trae Usage:")
                        lines.append("  total=\(snapshot.totalCredits)")
                        lines.append("  used=\(snapshot.usedCredits)")
                        lines.append("  plan=\(snapshot.planName)")
                        if let expiry = snapshot.expiresAt {
                            lines.append("  expires=\(expiry)")
                        }
                    } catch {
                        lines.append("")
                        lines.append("Parse Error: \(error.localizedDescription)")
                    }
                }
            } else {
                lines.append("")
                lines.append("Error: HTTP \(httpResponse.statusCode)")
            }

            let output = lines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(output) }
            return output
        } catch {
            lines.append("")
            lines.append("Probe Failed: \(error.localizedDescription)")
            let output = lines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(output) }
            return output
        }
    }

    public static func latestDumps() async -> String {
        await MainActor.run {
            let result = Self.recentDumps.joined(separator: "\n\n---\n\n")
            return result.isEmpty ? "No Trae probe dumps captured yet." : result
        }
    }

    @MainActor private static func recordDump(_ text: String) {
        if self.recentDumps.count >= 5 { self.recentDumps.removeFirst() }
        self.recentDumps.append(text)
    }
}
