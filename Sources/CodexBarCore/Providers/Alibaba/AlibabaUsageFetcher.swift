import Foundation

enum AlibabaUsageError: Error, CustomStringConvertible {
    case missingCookies
    case pageLoadFailed
    case parseFailed(String)
    case apiError(String)

    var description: String {
        switch self {
        case .missingCookies:
            return "Missing Alibaba Cloud cookies. Please log in to alibabacloud.com"
        case .pageLoadFailed:
            return "Failed to load Alibaba Cloud console"
        case .parseFailed(let detail):
            return "Failed to parse usage data: \(detail)"
        case .apiError(let detail):
            return "API error: \(detail)"
        }
    }
}

enum AlibabaUsageFetcher {
    /// Fetch usage data from Alibaba Cloud console via WebView scraping
    static func fetchUsage(
        cookieImporter: any BrowserCookieImporting,
        webViewAPI: any WebViewAPI,
        webTimeout: TimeInterval
    ) async throws -> AlibabaUsageSnapshot {
        // Get cookies for authentication
        guard let cookies = await cookieImporter.cookies(for: "alibabacloud.com") else {
            throw AlibabaUsageError.missingCookies
        }

        // Create WebView and load console
        let webView = webViewAPI.makeWebView()
        defer { webView.close() }

        let consoleURL = "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=globalset#/efm/coding_plan"

        // Navigate to console with cookies using configured timeout
        try await webView.load(url: consoleURL, cookies: cookies, timeout: webTimeout)

        // Wait for usage selectors to appear instead of fixed sleep
        // Usage cards are in [ref="e168"], [ref="e187"], [ref="e206"]
        // Poll for up to 10 seconds with 500ms intervals
        let usageSelectors = ["e168", "e187", "e206"]
        var allSelectorsReady = false
        
        for attempt in 1...20 { // 20 attempts × 500ms = 10 seconds max
            var readyCount = 0
            for selector in usageSelectors {
                // Check if element exists by returning a primitive (not bridging DOM object)
                let script = "document.querySelector('[ref=\"\(selector)\"]') !== null"
                if let exists = try await webView.evaluateJavaScript(script) as? Bool, exists {
                    readyCount += 1
                }
            }
            if readyCount == usageSelectors.count {
                allSelectorsReady = true
                break
            }
            if attempt < 20 {
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
        
        guard allSelectorsReady else {
            throw AlibabaUsageError.pageLoadFailed
        }

        // Extract usage data via JavaScript
        let script = """
        (function() {
            function getText(ref) {
                const el = document.querySelector('[ref="' + ref + '"]');
                return el ? el.innerText.trim() : null;
            }

            return {
                plan: getText('e98'),
                status: getText('e111'),
                remainingDays: getText('e116'),
                startTime: getText('e121'),
                endTime: getText('e126'),
                usage5h: getText('e168'),
                usage5hReset: getText('e167'),
                usage7d: getText('e187'),
                usage7dReset: getText('e186'),
                usage30d: getText('e206'),
                usage30dReset: getText('e205')
            };
        })()
        """

        guard let result = try await webView.evaluateJavaScript(script) as? [String: Any?],
              let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let response = try? JSONDecoder().decode(AlibabaConsoleResponse.self, from: jsonData)
        else {
            throw AlibabaUsageError.parseFailed("Could not extract usage data from DOM")
        }

        // Validate that ALL required usage fields are present
        // This prevents partial selector drift from producing misleading quota signals
        // If any window selector breaks, we should fail fast rather than show 0.0%
        guard response.usage5h != nil && response.usage7d != nil && response.usage30d != nil else {
            let missingFields: [String] = {
                var missing: [String] = []
                if response.usage5h == nil { missing.append("5h") }
                if response.usage7d == nil { missing.append("7d") }
                if response.usage30d == nil { missing.append("30d") }
                return missing
            }()
            throw AlibabaUsageError.parseFailed("Missing usage fields: \(missingFields.joined(separator: ", ")). Selectors may have drifted or page not rendered")
        }

        // Parse the response into usage snapshot
        return parseUsageResponse(response)
    }

    private static func parseUsageResponse(_ response: AlibabaConsoleResponse) throws -> AlibabaUsageSnapshot {
        // Parse percentage strings like "9%", "46%", "63%"
        // CRITICAL: Do NOT default to 0.0 - throw error if parsing fails
        // This prevents silently showing 0% when selectors drift or page format changes
        guard let usage5hPercent = parsePercentage(response.usage5h) else {
            throw AlibabaUsageError.parseFailed("Failed to parse 5h usage: '\(response.usage5h ?? "nil")'")
        }
        guard let usage7dPercent = parsePercentage(response.usage7d) else {
            throw AlibabaUsageError.parseFailed("Failed to parse 7d usage: '\(response.usage7d ?? "nil")'")
        }
        guard let usage30dPercent = parsePercentage(response.usage30d) else {
            throw AlibabaUsageError.parseFailed("Failed to parse 30d usage: '\(response.usage30d ?? "nil")'")
        }

        // Calculate reset times
        let reset5h = parseResetTime(response.usage5hReset) ?? Date().addingTimeInterval(5 * 60 * 60)
        let reset7d = parseResetTime(response.usage7dReset) ?? Date().addingTimeInterval(7 * 24 * 60 * 60)
        let reset30d = parseResetTime(response.usage30dReset) ?? Date().addingTimeInterval(30 * 24 * 60 * 60)

        return AlibabaUsageSnapshot(
            plan: response.plan ?? "Unknown",
            status: response.status ?? "Unknown",
            remainingDays: response.remainingDays ?? "",
            sessionUsage: RateWindow(
                usedPercent: usage5hPercent,
                windowMinutes: 300, // 5 hours
                resetsAt: reset5h,
                resetDescription: "Resets in 5 hours"
            ),
            weeklyUsage: RateWindow(
                usedPercent: usage7dPercent,
                windowMinutes: 10080, // 7 days
                resetsAt: reset7d,
                resetDescription: "Resets weekly"
            ),
            monthlyUsage: RateWindow(
                usedPercent: usage30dPercent,
                windowMinutes: 43200, // 30 days
                resetsAt: reset30d,
                resetDescription: "Resets monthly"
            ),
            updatedAt: Date()
        )
    }

    private static func parsePercentage(_ string: String?) -> Double? {
        guard let string = string, !string.isEmpty else { return nil }
        let cleaned = string.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let percent = Double(cleaned) else {
            // String exists but is not a valid number - this indicates selector drift or malformed data
            return nil
        }
        return percent
    }

    private static func parseResetTime(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        // Expected format: "2026-03-17 06:57:57 Reset" or "2026-03-17 06:57:57" (possibly with localized suffix)
        // Extract just the timestamp portion (first 19 chars: "yyyy-MM-dd HH:mm:ss")
        // This avoids assuming English "Reset" suffix or any specific localized text
        let timestampLength = 19 // "yyyy-MM-dd HH:mm:ss"
        guard string.count >= timestampLength else { return nil }
        let dateString = String(string.prefix(timestampLength)).trimmingCharacters(in: .whitespaces)
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        // Don't set explicit timezone - use system timezone to match displayed console time
        // Users in Singapore will see SGT times, users in PY will see PYT times, etc.
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return dateFormatter.date(from: dateString)
    }
}

/// Response from JavaScript extraction
struct AlibabaConsoleResponse: Codable {
    let plan: String?
    let status: String?
    let remainingDays: String?
    let startTime: String?
    let endTime: String?
    let usage5h: String?
    let usage5hReset: String?
    let usage7d: String?
    let usage7dReset: String?
    let usage30d: String?
    let usage30dReset: String?

    enum CodingKeys: String, CodingKey {
        case plan, status, remainingDays, startTime, endTime
        case usage5h = "usage5h"
        case usage5hReset = "usage5hReset"
        case usage7d = "usage7d"
        case usage7dReset = "usage7dReset"
        case usage30d = "usage30d"
        case usage30dReset = "usage30dReset"
    }
}
