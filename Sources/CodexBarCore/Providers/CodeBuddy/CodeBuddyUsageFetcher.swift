import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodeBuddyUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.codeBuddyAPI)
    private static let usageURL =
        URL(string: "https://tencent.sso.codebuddy.cn/billing/meter/get-enterprise-user-usage")!
    private static let dailyUsageURL =
        URL(string: "https://tencent.sso.codebuddy.cn/billing/meter/get-user-daily-usage")!
    private static let baseURL = "https://tencent.sso.codebuddy.cn"

    public static func fetchUsage(
        cookieHeader: String,
        enterpriseID: String,
        now: Date = Date()) async throws -> CodeBuddyUsageSnapshot
    {
        Self.log.debug("Fetching usage with enterpriseID=\(enterpriseID), cookieLength=\(cookieHeader.count)")

        var request = URLRequest(url: self.usageURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(enterpriseID, forHTTPHeaderField: "x-enterprise-id")
        request.setValue(self.baseURL, forHTTPHeaderField: "Origin")
        request.setValue("\(self.baseURL)/profile/usage", forHTTPHeaderField: "Referer")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Empty JSON body as required by the API
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodeBuddyAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("CodeBuddy API returned \(httpResponse.statusCode): \(responseBody)")

            if httpResponse.statusCode == 401 {
                throw CodeBuddyAPIError.invalidCookies
            }
            if httpResponse.statusCode == 403 {
                throw CodeBuddyAPIError.invalidCookies
            }
            if httpResponse.statusCode == 400 {
                throw CodeBuddyAPIError.invalidRequest("Bad request")
            }
            throw CodeBuddyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let usageResponse = try JSONDecoder().decode(CodeBuddyUsageResponse.self, from: data)

        if usageResponse.code != 0 {
            throw CodeBuddyAPIError.apiError("API error: \(usageResponse.msg)")
        }

        return CodeBuddyUsageSnapshot(
            creditUsed: usageResponse.data.credit,
            creditLimit: usageResponse.data.limitNum,
            cycleStartTime: usageResponse.data.cycleStartTime,
            cycleEndTime: usageResponse.data.cycleEndTime,
            cycleResetTime: usageResponse.data.cycleResetTime,
            updatedAt: now)
    }

    /// Attempt to detect enterprise ID by probing the API
    /// This can be used when enterprise ID is not explicitly configured
    public static func detectEnterpriseID(cookieHeader: String) async throws -> String? {
        // For now, enterprise ID must be provided manually or extracted from the dashboard page
        // Future enhancement: parse the dashboard HTML to extract the enterprise ID
        return nil
    }

    /// Fetch daily usage for the last 30 days
    public static func fetchDailyUsage(
        cookieHeader: String,
        enterpriseID: String,
        now: Date = Date()) async throws -> [CodeBuddyDailyUsageEntry]
    {
        // Calculate date range: last 30 days
        let calendar = Calendar.current
        let shanghaiTZ = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var calendarWithTZ = calendar
        calendarWithTZ.timeZone = shanghaiTZ

        let endDate = now
        guard let startDate = calendarWithTZ.date(byAdding: .day, value: -30, to: endDate) else {
            return []
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = shanghaiTZ

        // Set start time to beginning of day, end time to end of day
        let startOfDay = calendarWithTZ.startOfDay(for: startDate)
        let endOfDay = calendarWithTZ.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate

        let startTimeStr = dateFormatter.string(from: startOfDay)
        let endTimeStr = dateFormatter.string(from: endOfDay)

        var request = URLRequest(url: self.dailyUsageURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(enterpriseID, forHTTPHeaderField: "x-enterprise-id")
        request.setValue(self.baseURL, forHTTPHeaderField: "Origin")
        request.setValue("\(self.baseURL)/profile/usage", forHTTPHeaderField: "Referer")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Request body with date range and pagination
        let bodyDict: [String: Any] = [
            "startTime": startTimeStr,
            "endTime": endTimeStr,
            "pageNum": 1,
            "pageSize": 31, // Request 31 days to ensure we get all 30
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            Self.log.error("CodeBuddy daily usage API: Invalid response")
            return []
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("CodeBuddy daily usage API returned \(httpResponse.statusCode): \(responseBody)")
            return []
        }

        let dailyResponse = try JSONDecoder().decode(CodeBuddyDailyUsageResponse.self, from: data)

        if dailyResponse.code != 0 {
            Self.log.error("CodeBuddy daily usage API error: \(dailyResponse.msg)")
            return []
        }

        // Convert to public entry type
        return dailyResponse.data.data.map { entry in
            CodeBuddyDailyUsageEntry(date: entry.date, credit: entry.credit)
        }
    }
}
