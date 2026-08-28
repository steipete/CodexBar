import Foundation

#if os(macOS)
import SweetCookieKit

private let alibabaCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.alibaba]?.browserCookieOrder ?? Browser.defaultImportOrder

/// Alibaba-specific entry point for the shared OneConsole cookie importer.
public enum AlibabaCodingPlanCookieImporter {
    public typealias SessionInfo = AliyunOneConsoleCookieImporter.SessionInfo

    private static let cookieDomains = [
        "bailian-singapore-cs.alibabacloud.com",
        "bailian-cs.console.aliyun.com",
        "bailian-beijing-cs.aliyuncs.com",
        "modelstudio.console.alibabacloud.com",
        "bailian.console.aliyun.com",
        "free.aliyun.com",
        "account.aliyun.com",
        "signin.aliyun.com",
        "passport.alibabacloud.com",
        "console.alibabacloud.com",
        "console.aliyun.com",
        "alibabacloud.com",
        "aliyun.com",
    ]

    #if DEBUG
    final class ImportSessionOverrideStore: @unchecked Sendable {
        let importSession: (BrowserDetection, ((String) -> Void)?) throws -> SessionInfo

        init(importSession: @escaping (BrowserDetection, ((String) -> Void)?) throws -> SessionInfo) {
            self.importSession = importSession
        }
    }

    @TaskLocal private static var taskImportSessionOverrideStore: ImportSessionOverrideStore?

    static func withImportSessionOverrideForTesting<T>(
        _ override: ((BrowserDetection, ((String) -> Void)?) throws -> SessionInfo)?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskImportSessionOverrideStore.withValue(override.map(ImportSessionOverrideStore.init)) {
            try operation()
        }
    }

    static func withImportSessionOverrideForTesting<T>(
        _ override: ((BrowserDetection, ((String) -> Void)?) throws -> SessionInfo)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskImportSessionOverrideStore.withValue(override.map(ImportSessionOverrideStore.init)) {
            try await operation()
        }
    }
    #endif

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        #if DEBUG
        if let override = self.taskImportSessionOverrideStore?.importSession {
            return try override(browserDetection, logger)
        }
        #endif
        do {
            return try AliyunOneConsoleCookieImporter.importSession(
                browserDetection: browserDetection,
                domains: self.cookieDomains,
                isAuthenticatedSession: self.isAuthenticatedSession(cookies:),
                logPrefix: "alibaba-cookie",
                sessionLabel: "Alibaba",
                importOrder: alibabaCookieImportOrder,
                logger: logger)
        } catch let error as AliyunOneConsoleCookieImportError {
            throw AlibabaCodingPlanSettingsError.missingCookie(details: error.details)
        }
    }

    static func isAuthenticatedSession(cookies: [HTTPCookie]) -> Bool {
        guard !cookies.isEmpty else { return false }
        let names = Set(cookies.map(\.name))
        let hasTicket = names.contains("login_aliyunid_ticket")
        let hasAccount =
            names.contains("login_aliyunid_pk") ||
            names.contains("login_current_pk") ||
            names.contains("login_aliyunid")
        return hasTicket && hasAccount
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        AliyunOneConsoleCookieImporter.hasSession(
            browserDetection: browserDetection,
            domains: self.cookieDomains,
            isAuthenticatedSession: self.isAuthenticatedSession(cookies:),
            logPrefix: "alibaba-cookie",
            sessionLabel: "Alibaba",
            importOrder: alibabaCookieImportOrder,
            logger: logger)
    }

    static func cookieImportCandidates(
        browserDetection: BrowserDetection,
        importOrder: BrowserCookieImportOrder = alibabaCookieImportOrder) -> [Browser]
    {
        AliyunOneConsoleCookieImporter.cookieImportCandidates(
            browserDetection: browserDetection,
            importOrder: importOrder)
    }

    static func matchesCookieDomain(_ domain: String, patterns: [String] = Self.cookieDomains) -> Bool {
        AliyunOneConsoleCookieImporter.matchesCookieDomain(domain, patterns: patterns)
    }

    static func normalizeCookieDomain(_ domain: String) -> String {
        AliyunOneConsoleCookieImporter.normalizeCookieDomain(domain)
    }
}
#endif
