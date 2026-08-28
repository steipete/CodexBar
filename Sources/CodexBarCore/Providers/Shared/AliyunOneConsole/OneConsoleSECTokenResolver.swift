import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves the Aliyun OneConsole `sec_token` for a given authenticated
/// session. The token is required for every gateway API call; it lives
/// either in the dashboard HTML (as an inline JS constant), on the user-info
/// endpoint, or as a cookie scoped to the console host. Providers configure
/// which sources to probe and how to recognize their login page.
public struct OneConsoleSECTokenResolver: Sendable {
    public struct Configuration: Sendable {
        /// Resolves the dashboard URL for the current environment (host override aware).
        public let dashboardURL: @Sendable ([String: String]) -> URL
        /// Path under the dashboard host to the user-info JSON endpoint (typically "tool/user/info.json").
        public let userInfoPath: String
        /// Provider-specific login-page detector. OneConsole providers use
        /// different passport hosts and login markup, so the provider owns this
        /// classification instead of flattening alternatives into shared rules.
        public let isLoginPage: @Sendable (String) -> Bool
        /// Additional regex patterns the provider wants to try beyond the
        /// built-in set (secToken, sec_token, csrfToken).
        public let extraHTMLPatterns: [String]

        public init(
            dashboardURL: @escaping @Sendable ([String: String]) -> URL,
            userInfoPath: String,
            isLoginPage: @escaping @Sendable (String) -> Bool,
            extraHTMLPatterns: [String] = [])
        {
            self.dashboardURL = dashboardURL
            self.userInfoPath = userInfoPath
            self.isLoginPage = isLoginPage
            self.extraHTMLPatterns = extraHTMLPatterns
        }
    }

    public enum Source: String, Sendable {
        case dashboardHTML = "dashboard-html"
        case cookie
        case userInfo = "user-info"
    }

    public struct Resolved: Sendable, Equatable {
        public let value: String
        public let source: Source
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func resolve(
        cookieHeader: String,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> Resolved
    {
        let dashboardURL = self.configuration.dashboardURL(environment)

        // 1. Try the dashboard HTML. The one-console injects sec_token as an
        // inline JS constant; it's the freshest source.
        var dashboardFailure: Error?
        do {
            let token = try await self.fetchFromDashboard(
                cookieHeader: cookieHeader,
                dashboardURL: dashboardURL,
                transport: transport)
            return Resolved(value: token, source: .dashboardHTML)
        } catch OneConsoleSECTokenError.notFound {
            // Continue through the token fallbacks.
        } catch {
            dashboardFailure = error
        }

        // 2. Fall back to a sec_token cookie scoped to the console host.
        if let cookieToken = Self.secTokenCookieValue(from: cookieHeader, host: dashboardURL.host) {
            return Resolved(value: cookieToken, source: .cookie)
        }

        // 3. Final fallback: the user-info JSON endpoint.
        do {
            let userInfoToken = try await self.fetchFromUserInfo(
                cookieHeader: cookieHeader,
                dashboardURL: dashboardURL,
                transport: transport)
            return Resolved(value: userInfoToken, source: .userInfo)
        } catch OneConsoleSECTokenError.notFound {
            // A retained dashboard failure is more accurate than missing credentials.
        } catch {
            throw error
        }

        if let dashboardFailure {
            throw dashboardFailure
        }

        throw OneConsoleSECTokenError.notFound
    }

    // MARK: - Dashboard HTML

    private func fetchFromDashboard(
        cookieHeader: String,
        dashboardURL: URL,
        transport: any ProviderHTTPTransport) async throws -> String
    {
        var request = URLRequest(url: dashboardURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            if (500...599).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            throw OneConsoleSECTokenError.notFound
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw OneConsoleSECTokenError.notFound
        }
        if self.configuration.isLoginPage(html) {
            throw OneConsoleSECTokenError.notFound
        }
        if let token = Self.extractToken(from: html, extraPatterns: self.configuration.extraHTMLPatterns) {
            return token
        }
        throw OneConsoleSECTokenError.notFound
    }

    private static func extractToken(from html: String, extraPatterns: [String]) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"csrfToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
        ] + extraPatterns
        for pattern in patterns {
            if let token = Self.firstMatchGroup(pattern: pattern, in: html), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func firstMatchGroup(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    // MARK: - Cookie fallback

    private static func secTokenCookieValue(from cookieHeader: String, host: String?) -> String? {
        var fallback: String?
        for pair in CookieHeaderNormalizer.pairs(from: cookieHeader) {
            guard pair.name.lowercased() == "sec_token", !pair.value.isEmpty else { continue }
            if let host, pair.value.contains(host) {
                return pair.value
            }
            fallback = pair.value
        }
        return fallback
    }

    // MARK: - User-info fallback

    private func fetchFromUserInfo(
        cookieHeader: String,
        dashboardURL: URL,
        transport: any ProviderHTTPTransport) async throws -> String
    {
        var components = URLComponents()
        components.scheme = dashboardURL.scheme ?? "https"
        guard let dashboardHost = dashboardURL.host else {
            throw OneConsoleSECTokenError.notFound
        }
        components.host = dashboardHost
        if let port = dashboardURL.port {
            components.port = port
        }
        components.path = self.configuration.userInfoPath
        guard let url = components.url else {
            throw OneConsoleSECTokenError.notFound
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OneConsoleSECTokenError.notFound
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw OneConsoleSECTokenError.notFound
        }
        let expanded = OneConsoleJSON.expandEmbeddedJSON(json)
        if let token = OneConsoleJSON.findFirstString(
            forKeys: ["secToken", "sec_token", "csrfToken", "token"],
            in: expanded)
        {
            return token
        }
        throw OneConsoleSECTokenError.notFound
    }
}

public enum OneConsoleSECTokenError: LocalizedError, Sendable {
    case notFound

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "sec_token not found in dashboard, cookies, or user-info"
        }
    }
}
