import Foundation

public enum AuditCategory: String, Codable, Sendable {
    case network
    case command
    case secret
}

public enum AuditRisk: String, Codable, Sendable {
    case normal
    case sensitive
    case elevatedRisk = "elevated-risk"
}

public struct GovernanceContext: Codable, Sendable, Equatable {
    public let flow: String
    public let detail: String?

    public init(flow: String, detail: String? = nil) {
        self.flow = flow
        self.detail = detail
    }
}

public struct AuditEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let category: AuditCategory
    public let action: String
    public let target: String
    public let risk: AuditRisk
    public let metadata: [String: String]
    public let context: GovernanceContext?

    public init(
        timestamp: Date = Date(),
        category: AuditCategory,
        action: String,
        target: String,
        risk: AuditRisk = .normal,
        metadata: [String: String] = [:],
        context: GovernanceContext? = nil)
    {
        self.timestamp = timestamp
        self.category = category
        self.action = action
        self.target = target
        self.risk = risk
        self.metadata = metadata
        self.context = context
    }
}
