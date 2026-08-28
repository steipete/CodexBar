import Foundation

public struct AliyunOneConsoleCookieImportError: LocalizedError, Sendable {
    public let details: String?

    public init(details: String? = nil) {
        self.details = details
    }

    public var errorDescription: String? {
        self.details
    }
}

#if os(macOS)
import SweetCookieKit

/// Generic browser-cookie importer for Aliyun OneConsole-based providers.
///
/// Each provider (Alibaba Coding Plan, Alibaba Token Plan, Qwen Cloud, ...) declares
/// its own cookie domains and "is this an authenticated session" predicate. Everything
/// else -- the per-browser iteration, Chromium fallback, Keychain preflight, and
/// diagnostic collection -- is shared here.
public enum AliyunOneConsoleCookieImporter {
    private static let cookieClient = BrowserCookieClient()

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            var byName: [String: HTTPCookie] = [:]
            byName.reserveCapacity(self.cookies.count)

            for cookie in self.cookies {
                if let expiry = cookie.expiresDate, expiry < Date() {
                    continue
                }
                guard !cookie.value.isEmpty else { continue }
                if let existing = byName[cookie.name] {
                    let existingExpiry = existing.expiresDate ?? .distantPast
                    let candidateExpiry = cookie.expiresDate ?? .distantPast
                    if candidateExpiry >= existingExpiry {
                        byName[cookie.name] = cookie
                    }
                } else {
                    byName[cookie.name] = cookie
                }
            }

            return byName.keys.sorted().compactMap { name in
                guard let cookie = byName[name] else { return nil }
                return "\(cookie.name)=\(cookie.value)"
            }.joined(separator: "; ")
        }
    }

    /// Generic browser-cookie import for Aliyun OneConsole-based providers.
    /// The domain list, session-validation rules, and browser-import order are
    /// provider-specific; everything else is shared.
    public static func importSession(
        browserDetection: BrowserDetection,
        domains: [String],
        isAuthenticatedSession: @escaping ([HTTPCookie]) -> Bool,
        logPrefix: String,
        sessionLabel: String,
        importOrder: BrowserCookieImportOrder = Browser.defaultImportOrder,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[\(logPrefix)] \(msg)") }
        var accessDeniedHints: [String] = []
        var failureDetails: [String] = []
        let installedBrowsers = self.cookieImportCandidates(
            browserDetection: browserDetection,
            importOrder: importOrder)
        log("Cookie import candidates: \(installedBrowsers.map(\.displayName).joined(separator: ", "))")

        for browserSource in installedBrowsers {
            do {
                log("Checking \(browserSource.displayName)")
                let query = BrowserCookieQuery(domains: domains)
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
                if sources.isEmpty {
                    log("No matching cookie records in \(browserSource.displayName)")
                    if let fallbackSession = try Self.importChromiumFallbackSession(
                        browser: browserSource,
                        domains: domains,
                        isAuthenticatedSession: isAuthenticatedSession,
                        sessionLabel: sessionLabel,
                        logger: log)
                    {
                        return fallbackSession
                    }
                }
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if isAuthenticatedSession(httpCookies) {
                        log("Found \(httpCookies.count) \(sessionLabel) cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    }
                    log(
                        "Skipping \(source.label): missing auth cookies" +
                            " (\(httpCookies.count) cookies)")
                }
                if let fallbackSession = try Self.importChromiumFallbackSession(
                    browser: browserSource,
                    domains: domains,
                    isAuthenticatedSession: isAuthenticatedSession,
                    sessionLabel: sessionLabel,
                    logger: log)
                {
                    return fallbackSession
                }
            } catch let error as BrowserCookieError {
                BrowserCookieAccessGate.recordIfNeeded(error)
                if let hint = error.accessDeniedHint {
                    accessDeniedHints.append(hint)
                }
                failureDetails.append("\(browserSource.displayName): \(error.localizedDescription)")
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            } catch {
                failureDetails.append("\(browserSource.displayName): \(error.localizedDescription)")
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        let details = (Array(Set(accessDeniedHints)).sorted() + Array(Set(failureDetails)).sorted())
            .joined(separator: " ")
        throw AliyunOneConsoleCookieImportError(details: details.isEmpty ? nil : details)
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        domains: [String],
        isAuthenticatedSession: @escaping ([HTTPCookie]) -> Bool,
        logPrefix: String,
        sessionLabel: String,
        importOrder: BrowserCookieImportOrder = Browser.defaultImportOrder,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            _ = try self.importSession(
                browserDetection: browserDetection,
                domains: domains,
                isAuthenticatedSession: isAuthenticatedSession,
                logPrefix: logPrefix,
                sessionLabel: sessionLabel,
                importOrder: importOrder,
                logger: logger)
            return true
        } catch {
            return false
        }
    }

    private static func importChromiumFallbackSession(
        browser: Browser,
        domains: [String],
        isAuthenticatedSession: @escaping ([HTTPCookie]) -> Bool,
        sessionLabel: String,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo?
    {
        guard browser.usesChromiumProfileStore else { return nil }
        guard let fallbackSession = try AliyunOneConsoleChromiumCookieFallbackImporter.importSession(
            browser: browser,
            domains: domains,
            isAuthenticatedSession: isAuthenticatedSession,
            sessionLabel: sessionLabel,
            logger: logger)
        else {
            return nil
        }
        guard isAuthenticatedSession(fallbackSession.cookies) else {
            logger?(
                "Fallback cookies missing auth cookies" +
                    " (\(fallbackSession.cookies.count) cookies); ignoring" +
                    " \(fallbackSession.sourceLabel)")
            return nil
        }
        logger?(
            "Using fallback import (\(fallbackSession.cookies.count) \(sessionLabel) cookies)" +
                " from \(fallbackSession.sourceLabel)")
        return fallbackSession
    }

    public static func cookieImportCandidates(
        browserDetection: BrowserDetection,
        importOrder: BrowserCookieImportOrder) -> [Browser]
    {
        importOrder.cookieImportCandidates(using: browserDetection)
    }

    public static func matchesCookieDomain(_ domain: String, patterns: [String]) -> Bool {
        let normalized = self.normalizeCookieDomain(domain)
        return patterns.contains { pattern in
            let normalizedPattern = self.normalizeCookieDomain(pattern)
            return normalized == normalizedPattern || normalized.hasSuffix(".\(normalizedPattern)")
        }
    }

    public static func normalizeCookieDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        return normalized.lowercased()
    }
}
#endif
