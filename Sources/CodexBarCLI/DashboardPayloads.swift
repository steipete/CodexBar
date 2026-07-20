import CodexBarCore
import Foundation

/// How much account identity a dashboard snapshot exposes. `codexbar serve`
/// always uses `.redacted`; the other modes exist for the builder contract.
enum DashboardIdentityMode: String, Equatable, Sendable {
    case none
    case redacted
    case full
}

struct DashboardSnapshotPayload: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let staleAfterSeconds: Int
    let host: DashboardHostPayload
    let providers: [DashboardProviderPayload]
}

struct DashboardHostPayload: Encodable {
    let codexBarVersion: String?
    let refreshIntervalSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case codexBarVersion
        case refreshIntervalSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.codexBarVersion, forKey: .codexBarVersion)
        try container.encode(self.refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
    }
}

struct DashboardProviderPayload: Encodable {
    let id: String
    let name: String
    let enabled: Bool
    let source: String
    let status: DashboardStatusPayload?
    let identity: DashboardIdentityPayload?
    let windows: [DashboardWindowPayload]
    let credits: DashboardCreditsPayload?
    let cost: DashboardCostPayload?
    let display: DashboardDisplayPayload
    let error: ProviderErrorPayload?
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case source
        case status
        case identity
        case windows
        case credits
        case cost
        case display
        case error
        case updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.source, forKey: .source)
        try container.encode(self.status, forKey: .status)
        try container.encode(self.identity, forKey: .identity)
        try container.encode(self.windows, forKey: .windows)
        try container.encode(self.credits, forKey: .credits)
        try container.encode(self.cost, forKey: .cost)
        try container.encode(self.display, forKey: .display)
        try container.encode(self.error, forKey: .error)
        try container.encode(self.updatedAt, forKey: .updatedAt)
    }
}

struct DashboardStatusPayload: Encodable {
    let level: String
    let label: String
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case level
        case label
        case updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.level, forKey: .level)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.updatedAt, forKey: .updatedAt)
    }
}

struct DashboardIdentityPayload: Encodable {
    let accountEmail: String?
    let plan: String?

    private enum CodingKeys: String, CodingKey {
        case accountEmail
        case plan
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.accountEmail, forKey: .accountEmail)
        try container.encode(self.plan, forKey: .plan)
    }
}

struct DashboardWindowPayload: Encodable {
    let kind: String
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Date?

    private enum CodingKeys: String, CodingKey {
        case kind
        case label
        case usedPercent
        case remainingPercent
        case resetAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.usedPercent, forKey: .usedPercent)
        try container.encode(self.remainingPercent, forKey: .remainingPercent)
        try container.encode(self.resetAt, forKey: .resetAt)
    }
}

struct DashboardCreditsPayload: Encodable {
    let remaining: Double
    let unit: String
}

struct DashboardCostPayload: Encodable {
    let todayUSD: Double?
    let last30DaysUSD: Double?

    private enum CodingKeys: String, CodingKey {
        case todayUSD
        case last30DaysUSD
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.todayUSD, forKey: .todayUSD)
        try container.encode(self.last30DaysUSD, forKey: .last30DaysUSD)
    }
}

struct DashboardDisplayPayload: Encodable {
    let accentColor: String
    let sortKey: Int
    let priority: String
}
