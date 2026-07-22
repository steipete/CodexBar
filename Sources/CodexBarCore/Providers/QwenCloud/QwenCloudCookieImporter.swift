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

    /// Cookie names that prove an authenticated Qwen Cloud session. Locale
    /// preferences, account-id markers, and CSRF tokens are intentionally
    /// excluded: a browser profile that merely visited qwencloud.com already
    /// carries them while logged out, and treating such a profile as
    /// authenticated would make the fetcher send a ticketless request, receive
    /// `loginRequired`, and keep re-importing the same profile forever.
    static let authTicketCookies: Set<String> = [
        "login_aliyunid_ticket",
        "login_qwencloud_ticket",
        "qwen_sso_ticket",
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
        // Qwen Cloud uses its own login ticket for direct accounts and the
        // alibabacloud passport ticket for legacy/federated accounts. Accept SSO
        // tickets too so SAML/SSO logins work. Never accept locale/account-id
        // cookies on their own — logged-out profiles carry them as well.
        let names = Set(cookies.map(\.name))
        return !names.isDisjoint(with: self.authTicketCookies)
    }
}
#endif
