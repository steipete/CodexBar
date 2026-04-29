import Foundation

public struct KimiUsageRow: Codable, Sendable, Equatable {
    public let label: String
    public let used: Int
    public let limit: Int
    public let windowMinutes: Int?
    public let resetAt: String?

    public init(label: String, used: Int, limit: Int, windowMinutes: Int?, resetAt: String?) {
        self.label = label
        self.used = used
        self.limit = limit
        self.windowMinutes = windowMinutes
        self.resetAt = resetAt
    }
}

public struct KimiUsagePayload: Sendable, Equatable {
    public let summary: KimiUsageRow?
    public let limits: [KimiUsageRow]

    public init(summary: KimiUsageRow?, limits: [KimiUsageRow]) {
        self.summary = summary
        self.limits = limits
    }
}
