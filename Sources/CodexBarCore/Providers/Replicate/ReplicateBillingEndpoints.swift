import Foundation

/// Constants locked from Replicate dashboard frontend route table + billing UI field usage.
/// Source: public frontend bundle `index-BJr3klVG.js` route table (verified in task-2 discovery).
/// Update only when Replicate changes the dashboard network surface.
public enum ReplicateBillingEndpoints: Sendable {
    private static let baseURLString = "https://replicate.com"

    /// Domains passed to SweetCookieKit / BrowserCookieClient for Automatic import.
    /// Session cookie: Django-style `sessionid`; also import `csrftoken` for completeness.
    public static let cookieDomains = ["replicate.com"]

    public static let dashboardURLString = "https://replicate.com/account/billing"
    public static let timeoutSeconds: TimeInterval = 30

    // MARK: - Invoices (current-month spend)

    /// GET — returns invoices including the current `monthly-usage` row.
    ///
    /// JSON field mapping (menu-bar spend):
    /// - Filter `invoices[]` where `type == "monthly-usage"`.
    /// - Current invoice = first where `ended_before` is null or parses to a future date.
    /// - **Usage this month** (`currentMonthSpend`): `Number(invoice.total_cost_before_adjustments ?? "0")`.
    /// - Outstanding balance (optional): `Number(invoice.total_cost ?? "0")` — not the menu-bar metric.
    /// - `currencyCode`: USD implied when absent (amounts are string decimals).
    /// - Period: calendar month via `started_on` / `ended_before` on the draft monthly-usage invoice.
    public static func userInvoicesURL(username: String) -> URL {
        Self.apiURL(pathComponents: ["api", "users", username, "invoices"])
    }

    /// GET — org-scoped invoices (same response shape as user invoices).
    public static func organizationInvoicesURL(organizationName: String) -> URL {
        Self.apiURL(pathComponents: ["api", "organizations", organizationName, "invoices"])
    }

    // MARK: - Unused credit (prepaid balance)

    /// GET — prepaid unused credit.
    ///
    /// JSON field mapping:
    /// - **Credit balance** (`creditBalance`): `Number(unused_credit ?? "0")` (string number).
    /// - `link_to_add_credit` (optional URL string).
    public static func userUnusedCreditURL(username: String) -> URL {
        Self.apiURL(pathComponents: ["api", "users", username, "unused-credit"])
    }

    /// GET — org-scoped unused credit.
    public static func organizationUnusedCreditURL(organizationName: String) -> URL {
        Self.apiURL(pathComponents: ["api", "organizations", organizationName, "unused-credit"])
    }

    // MARK: - Account bootstrap (later tasks)

    /// Invoices/credit URLs require `{username}` and account kind (`user` vs `organization`).
    /// Bootstrap strategy: with session cookies, GET `dashboardURLString` and parse
    /// `<script type="application/json" id="react-component-props-...">` for
    /// `account: { kind, username }` from signed-in page props.
    ///
    /// Spend limit: no JSON read API found in the frontend bundle — only POST/form routes
    /// (`/users/{username}/settings/set-spend-limit`, `/orgs/{organization_name}/settings/set-spend-limit`).
    /// Omit `spendLimit` for v1 unless a live capture proves a readable field.

    private static func apiURL(pathComponents: [String]) -> URL {
        var url = URL(string: Self.baseURLString)!
        for component in pathComponents {
            url = url.appendingPathComponent(component)
        }
        return url
    }
}
