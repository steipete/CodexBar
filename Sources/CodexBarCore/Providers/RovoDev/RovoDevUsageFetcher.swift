import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

// MARK: - Errors

public enum RovoDevUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case invalidCredentials
    case configNotFound
    case parseFailed(String)
    case networkError(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Atlassian. Please visit your Atlassian site in a browser."
        case .invalidCredentials:
            "Atlassian session expired. Please log in again in your browser."
        case .configNotFound:
            "Atlassian CLI config not found at ~/.config/acli/global_auth_config.yaml. " +
                "Please run `acli` to set up your profile."
        case let .parseFailed(message):
            "Could not parse Rovo Dev usage: \(message)"
        case let .networkError(message):
            "Rovo Dev request failed: \(message)"
        case .noSessionCookie:
            "No Atlassian session cookie found. Please log in to your Atlassian site in your browser."
        }
    }
}

// MARK: - Config reader

/// Reads the ACLI global auth config to discover the active Atlassian site and cloud ID.
public struct RovoDevACLIConfig: Sendable {
    public let site: String       // e.g. "outreach-io.atlassian.net"
    public let cloudID: String    // e.g. "74570b23-8e0a-4453-a336-43a98125368f"

    /// URL for the allowance API.
    public var allowanceURL: URL {
        URL(string: "https://\(self.site)/gateway/api/rovodev/v3/credits/entitlements/entitlement-allowance")!
    }

    /// The Atlassian host used for cookie import.
    public var host: String { self.site }

    static let configPath: String = "~/.config/acli/global_auth_config.yaml"

    public static func load() throws -> RovoDevACLIConfig {
        let expanded = (Self.configPath as NSString).expandingTildeInPath
        guard let raw = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw RovoDevUsageError.configNotFound
        }
        return try Self.parse(raw)
    }

    static func parse(_ yaml: String) throws -> RovoDevACLIConfig {
        // Simple line-based YAML parsing – sufficient for the known config structure.
        var site: String?
        var cloudID: String?

        for line in yaml.components(separatedBy: "\n") {
            // Strip leading whitespace and YAML list indicator "- " so both
            // "site: foo" and "    - site: foo" forms are handled.
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") { trimmed = String(trimmed.dropFirst(2)) }
            if trimmed.hasPrefix("site:") {
                site = Self.value(after: "site:", in: trimmed)
            } else if trimmed.hasPrefix("cloud_id:") {
                cloudID = Self.value(after: "cloud_id:", in: trimmed)
            }
            if site != nil, cloudID != nil { break }
        }

        guard let site, let cloudID, !site.isEmpty, !cloudID.isEmpty else {
            throw RovoDevUsageError.parseFailed("Could not read site/cloud_id from ACLI config.")
        }
        return RovoDevACLIConfig(site: site, cloudID: cloudID)
    }

    private static func value(after prefix: String, in line: String) -> String? {
        let tail = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        // Strip surrounding quotes if present.
        if (tail.hasPrefix("\"") && tail.hasSuffix("\"")) ||
            (tail.hasPrefix("'") && tail.hasSuffix("'"))
        {
            let inner = tail.dropFirst().dropLast()
            return inner.isEmpty ? nil : String(inner)
        }
        return tail.isEmpty ? nil : tail
    }
}

// MARK: - Cookie importer

#if os(macOS)
public enum RovoDevCookieImporter {
    private static let cookieClient = BrowserCookieClient()

    public static func importSession(
        site: String,
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> String
    {
        let log: (String) -> Void = { msg in logger?("[rovodev-cookie] \(msg)") }
        let domains = [site, "atlassian.net", ".atlassian.net", "id.atlassian.com"]
        let candidates = Browser.defaultImportOrder.cookieImportCandidates(using: browserDetection)

        var allCookies: [HTTPCookie] = []
        for browser in candidates {
            do {
                let query = BrowserCookieQuery(domains: domains)
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query, in: browser, logger: log)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    allCookies.append(contentsOf: cookies)
                    if !cookies.isEmpty {
                        log("Found \(cookies.count) cookie(s) from \(browser.displayName)")
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browser.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        guard !allCookies.isEmpty else {
            throw RovoDevUsageError.noSessionCookie
        }

        let header = allCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header
    }
}
#endif

// MARK: - Fetcher

public struct RovoDevUsageFetcher: Sendable {
    @MainActor private static var recentDumps: [String] = []

    public let browserDetection: BrowserDetection
    private let makeURLSession: @Sendable (URLSessionTaskDelegate?) -> URLSession

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
        self.makeURLSession = { delegate in
            URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }
    }

    // MARK: Public API

    public func fetch(
        cookieHeaderOverride: String?,
        manualCookieMode: Bool,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> RovoDevUsageSnapshot
    {
        let config = try RovoDevACLIConfig.load()
        let cookieHeader = try await self.resolveCookieHeader(
            override: cookieHeaderOverride,
            manualCookieMode: manualCookieMode,
            site: config.site,
            logger: logger)
        return try await self.fetchAllowance(
            config: config,
            cookieHeader: cookieHeader,
            logger: logger,
            now: now)
    }

    // MARK: Debug

    public func debugRawProbe(
        cookieHeaderOverride: String? = nil,
        manualCookieMode: Bool = false) async -> String
    {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = ["=== Rovo Dev Debug Probe @ \(stamp) ===", ""]

        do {
            let config = try RovoDevACLIConfig.load()
            lines.append("Site: \(config.site)")
            lines.append("Cloud ID: \(config.cloudID)")

            let cookieHeader = try await self.resolveCookieHeader(
                override: cookieHeaderOverride,
                manualCookieMode: manualCookieMode,
                site: config.site,
                logger: { msg in lines.append("[cookie] \(msg)") })
            let cookieNames = CookieHeaderNormalizer.pairs(from: cookieHeader).map(\.name)
            lines.append("Cookie names: \(cookieNames.joined(separator: ", "))")

            let snap = try await self.fetchAllowance(
                config: config, cookieHeader: cookieHeader, logger: { msg in lines.append(msg) })
            lines.append("")
            lines.append("Fetch Success")
            lines.append("Current usage: \(snap.currentUsage)")
            lines.append("Credit cap: \(snap.creditCap)")
            lines.append("Used %: \(snap.creditCap > 0 ? Double(snap.currentUsage) / Double(snap.creditCap) * 100 : 0)")
            lines.append("Next refresh: \(snap.nextRefresh?.description ?? "nil")")
            lines.append("Entitlement: \(snap.effectiveEntitlement ?? "nil")")
        } catch {
            lines.append("")
            lines.append("Probe Failed: \(error.localizedDescription)")
        }

        let output = lines.joined(separator: "\n")
        Task { @MainActor in Self.recordDump(output) }
        return output
    }

    public static func latestDumps() async -> String {
        await MainActor.run {
            let result = Self.recentDumps.joined(separator: "\n\n---\n\n")
            return result.isEmpty ? "No Rovo Dev probe dumps captured yet." : result
        }
    }

    // MARK: Private

    private func resolveCookieHeader(
        override: String?,
        manualCookieMode: Bool,
        site: String,
        logger: ((String) -> Void)?) async throws -> String
    {
        if let normalized = CookieHeaderNormalizer.normalize(override), !normalized.isEmpty {
            logger?("[rovodev] Using manual cookie header")
            return normalized
        }
        if manualCookieMode {
            throw RovoDevUsageError.noSessionCookie
        }
        #if os(macOS)
        logger?("[rovodev] Importing cookies for \(site) from browser")
        return try RovoDevCookieImporter.importSession(
            site: site,
            browserDetection: self.browserDetection,
            logger: logger)
        #else
        throw RovoDevUsageError.noSessionCookie
        #endif
    }

    private func fetchAllowance(
        config: RovoDevACLIConfig,
        cookieHeader: String,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> RovoDevUsageSnapshot
    {
        let url = config.allowanceURL
        logger?("[rovodev] POST \(url)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "https://\(config.site)/rovodev/your-usage",
            forHTTPHeaderField: "Referer")
        request.setValue("https://\(config.site)", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let body: [String: String] = [
            "cloudId": config.cloudID,
            "entitlementId": "unknown",
            "productKey": "unknown",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let session = self.makeURLSession(nil)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RovoDevUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RovoDevUsageError.networkError("Invalid response")
        }
        logger?("[rovodev] HTTP \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw RovoDevUsageError.invalidCredentials
        default:
            throw RovoDevUsageError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return try Self.parseAllowance(data: data, now: now)
    }

    private static func parseAllowance(data: Data, now: Date) throws -> RovoDevUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RovoDevUsageError.parseFailed("Invalid JSON response.")
        }

        // Accept either Int or Double for numeric fields (Atlassian API returns integers).
        func intValue(_ key: String) -> Int? {
            if let v = json[key] as? Int { return v }
            if let v = json[key] as? Double { return Int(v) }
            return nil
        }

        guard let currentUsage = intValue("currentUsage"),
              let creditCap = intValue("creditCap"),
              creditCap > 0
        else {
            throw RovoDevUsageError.parseFailed("Missing currentUsage or creditCap in response.")
        }

        var nextRefresh: Date?
        if let ms = intValue("nextRefresh") {
            nextRefresh = Date(timeIntervalSince1970: Double(ms) / 1000)
        }

        let entitlement = json["effectiveEntitlement"] as? String
        // Email is not included in the allowance response; the caller may supply it separately.

        return RovoDevUsageSnapshot(
            currentUsage: currentUsage,
            creditCap: creditCap,
            nextRefresh: nextRefresh,
            effectiveEntitlement: entitlement,
            accountEmail: nil,
            updatedAt: now)
    }

    @MainActor private static func recordDump(_ text: String) {
        if Self.recentDumps.count >= 5 { Self.recentDumps.removeFirst() }
        Self.recentDumps.append(text)
    }
}
