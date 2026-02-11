import Foundation

/// API response for get-enterprise-user-usage endpoint
struct CodeBuddyUsageResponse: Codable {
    let code: Int
    let msg: String
    let requestId: String
    let data: CodeBuddyUsageData
}

struct CodeBuddyUsageData: Codable {
    let credit: Double
    let cycleStartTime: String
    let cycleEndTime: String
    let limitNum: Double
    let cycleResetTime: String
}

/// API response for get-user-daily-usage endpoint (for future use)
struct CodeBuddyDailyUsageResponse: Codable {
    let code: Int
    let msg: String
    let requestId: String
    let data: CodeBuddyDailyUsageData
}

struct CodeBuddyDailyUsageData: Codable {
    let total: Int
    let data: [CodeBuddyDailyUsage]
}

struct CodeBuddyDailyUsage: Codable {
    let credit: Double
    let date: String
}

/// Public daily usage entry for external access
public struct CodeBuddyDailyUsageEntry: Sendable {
    public let date: String // "yyyy-MM-dd" format
    public let credit: Double

    public init(date: String, credit: Double) {
        self.date = date
        self.credit = credit
    }
}
