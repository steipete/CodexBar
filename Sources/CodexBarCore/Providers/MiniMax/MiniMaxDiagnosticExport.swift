import Foundation

public struct MiniMaxDiagnosticExport: Codable, Sendable {
    public let timestamp: Date
    public let provider: String
    public let source: String
    public let authMode: String
    public let authConfigured: Bool
    public let usage: MiniMaxDiagnosticUsage?
    public let fetchAttempts: [MiniMaxDiagnosticFetchAttempt]
    public let error: MiniMaxDiagnosticError?
    public let settingsSummary: MiniMaxSettingsSummary

    public init(
        timestamp: Date,
        provider: String,
        source: String,
        authMode: String,
        authConfigured: Bool,
        usage: MiniMaxDiagnosticUsage?,
        fetchAttempts: [MiniMaxDiagnosticFetchAttempt],
        error: MiniMaxDiagnosticError?,
        settingsSummary: MiniMaxSettingsSummary)
    {
        self.timestamp = timestamp
        self.provider = provider
        self.source = source
        self.authMode = authMode
        self.authConfigured = authConfigured
        self.usage = usage
        self.fetchAttempts = fetchAttempts
        self.error = error
        self.settingsSummary = settingsSummary
    }
}

public struct MiniMaxDiagnosticUsage: Codable, Sendable {
    public let planName: String?
    public let availablePrompts: Int?
    public let currentPrompts: Int?
    public let remainingPrompts: Int?
    public let windowMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let services: [MiniMaxDiagnosticServiceUsage]?

    public init(
        planName: String?,
        availablePrompts: Int?,
        currentPrompts: Int?,
        remainingPrompts: Int?,
        windowMinutes: Int?,
        usedPercent: Double?,
        resetsAt: Date?,
        services: [MiniMaxDiagnosticServiceUsage]?)
    {
        self.planName = planName
        self.availablePrompts = availablePrompts
        self.currentPrompts = currentPrompts
        self.remainingPrompts = remainingPrompts
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.services = services
    }

    public init(from snapshot: MiniMaxUsageSnapshot) {
        self.planName = snapshot.planName
        self.availablePrompts = snapshot.availablePrompts
        self.currentPrompts = snapshot.currentPrompts
        self.remainingPrompts = snapshot.remainingPrompts
        self.windowMinutes = snapshot.windowMinutes
        self.usedPercent = snapshot.usedPercent
        self.resetsAt = snapshot.resetsAt
        self.services = snapshot.services?.map { MiniMaxDiagnosticServiceUsage(from: $0) }
    }
}

public struct MiniMaxDiagnosticServiceUsage: Codable, Sendable {
    public let displayName: String
    public let percent: Double
    public let windowType: String
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(from service: MiniMaxServiceUsage) {
        self.displayName = service.displayName
        self.percent = service.percent
        self.windowType = service.windowType
        self.resetsAt = service.resetsAt
        self.resetDescription = service.resetDescription
    }
}

public struct MiniMaxDiagnosticFetchAttempt: Codable, Sendable {
    public let kind: String
    public let wasAvailable: Bool
    public let errorCategory: String?

    public init(
        kind: String,
        wasAvailable: Bool,
        errorCategory: String?)
    {
        self.kind = kind
        self.wasAvailable = wasAvailable
        self.errorCategory = errorCategory
    }

    public init(from attempt: ProviderFetchAttempt) {
        self.kind = Self.kindLabel(attempt.kind)
        self.wasAvailable = attempt.wasAvailable
        self.errorCategory = attempt.errorDescription.map { Self.errorCategoryLabel($0) }
    }

    private static func kindLabel(_ kind: ProviderFetchKind) -> String {
        switch kind {
        case .cli: "cli"
        case .web: "web"
        case .oauth: "oauth"
        case .apiToken: "api"
        case .localProbe: "local"
        case .webDashboard: "web"
        }
    }

    private static func errorCategoryLabel(_ description: String?) -> String {
        guard let desc = description?.lowercased() else { return "unknown" }
        if desc.contains("network") || desc.contains("timeout") || desc.contains("connection") {
            return "network"
        }
        if desc.contains("auth") || desc.contains("credential") || desc.contains("token") || desc.contains("cookie") {
            return "auth"
        }
        if desc.contains("api") || desc.contains("http") || desc.contains("404") || desc.contains("403") {
            return "api"
        }
        if desc.contains("parse") || desc.contains("format") || desc.contains("decode") {
            return "parse"
        }
        return "unknown"
    }
}

public struct MiniMaxDiagnosticError: Codable, Sendable {
    public let category: String
    public let safeDescription: String

    public init(category: String, safeDescription: String) {
        self.category = category
        self.safeDescription = safeDescription
    }

    public init(from error: Error) {
        self.category = Self.errorCategory(error)
        self.safeDescription = Self.safeDescription(for: error)
    }

    private static func errorCategory(_ error: Error) -> String {
        if let minimaxError = error as? MiniMaxUsageError {
            switch minimaxError {
            case .networkError: return "network"
            case .invalidCredentials: return "auth"
            case .apiError: return "api"
            case .parseFailed: return "parse"
            }
        }
        if let settingsError = error as? MiniMaxSettingsError {
            switch settingsError {
            case .missingCookie: return "auth"
            }
        }
        if error is MiniMaxAPISettingsError { return "auth" }
        return "unknown"
    }

    private static func safeDescription(for error: Error) -> String {
        if let minimaxError = error as? MiniMaxUsageError {
            switch minimaxError {
            case .networkError:
                return "Network error - check your connection"
            case .invalidCredentials:
                return "Invalid credentials - please re-authenticate"
            case .apiError:
                return "API error - service returned an unexpected response"
            case .parseFailed:
                return "Parse error - unexpected response format"
            }
        }
        if let settingsError = error as? MiniMaxSettingsError {
            switch settingsError {
            case .missingCookie:
                return "Cookie not configured - import from browser or provide manually"
            }
        }
        if error is MiniMaxAPISettingsError {
            return "API settings error - check your token configuration"
        }
        return "An unexpected error occurred"
    }
}

public struct MiniMaxSettingsSummary: Codable, Sendable {
    public let apiRegion: String
    public let authMode: String

    public init(apiRegion: String, authMode: String) {
        self.apiRegion = apiRegion
        self.authMode = authMode
    }
}
