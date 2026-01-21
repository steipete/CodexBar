import Foundation

struct KimiUsageResponse: Codable {
    let usages: [KimiUsage]
}

struct KimiUsage: Codable {
    let scope: String
    let detail: KimiUsageDetail
    let limits: [KimiRateLimit]?
}

public struct KimiUsageDetail: Codable, Sendable {
    public let limit: String
    public let used: String? // Optional because rate limit detail doesn't have this
    public let remaining: String?
    public let resetTime: String

    public init(limit: String, used: String?, remaining: String?, resetTime: String) {
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.resetTime = resetTime
    }
}

struct KimiRateLimit: Codable {
    let window: KimiWindow
    let detail: KimiUsageDetail
}

struct KimiWindow: Codable {
    let duration: Int
    let timeUnit: String
}
