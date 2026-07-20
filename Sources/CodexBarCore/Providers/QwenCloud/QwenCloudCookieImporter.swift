#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Qwen Cloud (home.qwencloud.com) shares the Aliyun one-console auth backend, so its
/// session cookies live on `qwencloud.com` plus the alibabacloud/aliyun passport domains.
public enum QwenCloudCookieImport {
    static let cookieDomains: [String] = [
        "qwencloud.com",
        "home.qwencloud.com",
        "account.qwencloud.com",
        "signin.qwencloud.com",
        "www.qwencloud.com",
        "alibabacloud.com",
        "account.alibabacloud.com",
        "aliyun.com",
        "console.aliyun.com",
    ]

    static let recognizedSessionCookies: Set<String> = [
        "login_aliyunid_ticket",
        "login_aliyunid",
        "login_aliyunid_pk",
        "login_current_pk",
        "sec_token",
        "qwen_sso_ticket",
        "intl_locale",
    ]

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> AlibabaCodingPlanCookieImporter.SessionInfo
    {
        try AlibabaCodingPlanCookieImporter.importSession(
            browserDetection: browserDetection,
            domains: self.cookieDomains,
            isAuthenticatedSession: self.isAuthenticatedSession(cookies:),
            logPrefix: "qwen-cloud-cookie",
            sessionLabel: "Qwen Cloud",
            logger: logger)
    }

    static func isAuthenticatedSession(cookies: [HTTPCookie]) -> Bool {
        let names = Set(cookies.map(\.name))
        // Qwen Cloud international uses the alibabacloud passport; a valid console session
        // always carries the login ticket. Accept SSO tickets too so SAML/SSO logins work.
        if names.contains("login_aliyunid_ticket") || names.contains("qwen_sso_ticket") {
            return true
        }
        // Otherwise accept when at least one recognized session cookie scoped to a
        // Qwen Cloud host is present.
        return cookies.contains { cookie in
            guard Self.recognizedSessionCookies.contains(cookie.name) else { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain.hasSuffix("qwencloud.com")
        }
    }
}
#endif
