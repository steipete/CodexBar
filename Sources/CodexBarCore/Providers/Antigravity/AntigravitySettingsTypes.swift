import Foundation

public enum AntigravityPrimaryPoolPreference: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto
    case geminiWeekly = "gemini-weekly"
    case claudeGPTWeekly = "claude-gpt-weekly"
    case geminiFiveHour = "gemini-5h"
    case claudeGPTFiveHour = "claude-gpt-5h"

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto (most constrained)"
        case .geminiWeekly: "Gemini weekly"
        case .claudeGPTWeekly: "Claude/GPT weekly"
        case .geminiFiveHour: "Gemini 5-hour"
        case .claudeGPTFiveHour: "Claude/GPT 5-hour"
        }
    }

    public var preferredQuotaSummaryWindowID: String? {
        switch self {
        case .auto: nil
        case .geminiWeekly: "antigravity-quota-summary-gemini-weekly"
        case .claudeGPTWeekly: "antigravity-quota-summary-3p-weekly"
        case .geminiFiveHour: "antigravity-quota-summary-gemini-5h"
        case .claudeGPTFiveHour: "antigravity-quota-summary-3p-5h"
        }
    }

    /// Provider-specific by design: KnownFamily.gemini classifies an Antigravity quota family.
    var preferredFamily: AntigravityQuotaFamilyVisibility.KnownFamily? {
        switch self {
        case .auto: nil
        case .geminiWeekly, .geminiFiveHour: .gemini
        case .claudeGPTWeekly, .claudeGPTFiveHour: .claudeGPT
        }
    }

    var preferredWindowMinutes: Int? {
        switch self {
        case .auto: nil
        case .geminiWeekly, .claudeGPTWeekly: 10080
        case .geminiFiveHour, .claudeGPTFiveHour: 300
        }
    }
}

public enum AntigravityProjectGrouping: String, CaseIterable, Identifiable, Sendable, Codable {
    case workspace
    case gitRepository = "git-repository"

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .workspace: "Workspace directory"
        case .gitRepository: "Git repository"
        }
    }
}

public struct AntigravityLocalScanOptions: Sendable, Equatable, Hashable {
    public static let defaultOptions = Self()

    public var includeDesktopDatabases: Bool
    public var includeCLIDatabases: Bool
    public var includeTokscaleFallback: Bool
    public var projectGrouping: AntigravityProjectGrouping

    public init(
        includeDesktopDatabases: Bool = true,
        includeCLIDatabases: Bool = true,
        includeTokscaleFallback: Bool = true,
        projectGrouping: AntigravityProjectGrouping = .workspace)
    {
        self.includeDesktopDatabases = includeDesktopDatabases
        self.includeCLIDatabases = includeCLIDatabases
        self.includeTokscaleFallback = includeTokscaleFallback
        self.projectGrouping = projectGrouping
    }
}
