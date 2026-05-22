import Foundation

public enum AlibabaTokenPlanDebugProbe {
    public static func debugLog(
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String,
        environment: [String: String],
        browserDetection: BrowserDetection) async -> String
    {
        var lines: [String] = [
            "Alibaba Token Plan debug",
            "Cookie source: \(cookieSource.rawValue)",
        ]

        do {
            let headers = try self.resolveCookieHeaders(
                cookieSource: cookieSource,
                manualCookieHeader: manualCookieHeader,
                environment: environment,
                browserDetection: browserDetection,
                lines: &lines)
            lines.append("API cookie names: \(self.namesDescription(headers.apiCookieNames))")
            lines.append("Dashboard cookie names: \(self.namesDescription(headers.dashboardCookieNames))")
            lines.append("Has sec_token cookie: \(headers.hasCookie(named: "sec_token") ? "yes" : "no")")
            lines.append("Has login ticket: \(headers.hasCookie(named: "login_aliyunid_ticket") ? "yes" : "no")")
            lines.append("Has account cookie: \(self.hasAlibabaAccountCookie(headers) ? "yes" : "no")")

            do {
                let snapshot = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
                    apiCookieHeader: headers.apiCookieHeader,
                    dashboardCookieHeader: headers.dashboardCookieHeader,
                    environment: environment)
                lines.append("Fetch: success")
                lines.append("Plan present: \(snapshot.planName == nil ? "no" : "yes")")
                lines.append("Quota total present: \(snapshot.totalQuota == nil ? "no" : "yes")")
                lines.append("Quota used present: \(snapshot.usedQuota == nil ? "no" : "yes")")
                lines.append("Quota remaining present: \(snapshot.remainingQuota == nil ? "no" : "yes")")
                lines.append("Reset present: \(snapshot.resetsAt == nil ? "no" : "yes")")
            } catch {
                lines.append("Fetch: failed")
                lines.append("Fetch error: \(type(of: error))")
                lines.append("Fetch message: \(error.localizedDescription)")
            }
        } catch {
            lines.append("Cookie resolution: failed")
            lines.append("Cookie error: \(type(of: error))")
            lines.append("Cookie message: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    private static func resolveCookieHeaders(
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String,
        environment: [String: String],
        browserDetection: BrowserDetection,
        lines: inout [String]) throws -> AlibabaTokenPlanCookieHeaders
    {
        if cookieSource == .manual {
            let hasManualCookie = !manualCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lines.append("Manual cookie configured: \(hasManualCookie ? "yes" : "no")")
            guard let headers = AlibabaTokenPlanCookieHeaders(singleHeader: manualCookieHeader) else {
                throw AlibabaTokenPlanSettingsError.invalidCookie
            }
            lines.append("Cookie source selected: manual")
            return headers
        }

        if let envCookie = AlibabaTokenPlanSettingsReader.cookieHeader(environment: environment),
           let headers = AlibabaTokenPlanCookieHeaders(singleHeader: envCookie)
        {
            lines.append("Environment cookie configured: yes")
            lines.append("Cookie source selected: environment")
            return headers
        }
        lines.append("Environment cookie configured: no")

        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .alibabatokenplan) {
            lines.append("Cached browser cookie: yes")
            lines.append("Cached browser source: \(cached.sourceLabel)")
            if let headers = AlibabaTokenPlanCookieHeaders(cachedHeader: cached.cookieHeader) {
                lines.append("Cookie source selected: browser-cache")
                return headers
            }
            lines.append("Cached browser cookie parseable: no")
        } else {
            lines.append("Cached browser cookie: no")
        }

        var importLines: [String] = []
        let session = try AlibabaCodingPlanCookieImporter.importSession(
            browserDetection: browserDetection,
            logger: { importLines.append($0) })
        lines.append("Browser import source: \(session.sourceLabel)")
        if importLines.isEmpty {
            lines.append("Browser import log: empty")
        } else {
            lines.append("Browser import log:")
            lines.append(contentsOf: importLines.map { "  \($0)" })
        }

        let rawNames = session.cookies.map(\.name).filter { !$0.isEmpty }.uniquedSorted()
        lines.append("Raw imported cookie names: \(self.namesDescription(rawNames))")

        guard let headers = AlibabaTokenPlanCookieHeader.headers(from: session.cookies) else {
            throw AlibabaTokenPlanSettingsError.missingCookie(
                details: "No Alibaba Token Plan browser cookies were available after import.")
        }
        lines.append("Cookie source selected: browser-import")
        return headers
        #else
        throw AlibabaTokenPlanSettingsError.missingCookie(details: "Browser cookie import is only available on macOS.")
        #endif
    }

    private static func hasAlibabaAccountCookie(_ headers: AlibabaTokenPlanCookieHeaders) -> Bool {
        headers.hasCookie(named: "login_aliyunid_pk") ||
            headers.hasCookie(named: "login_current_pk") ||
            headers.hasCookie(named: "login_aliyunid")
    }

    private static func namesDescription(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

extension [String] {
    fileprivate func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
