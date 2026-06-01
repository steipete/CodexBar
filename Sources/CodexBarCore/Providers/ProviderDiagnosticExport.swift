import Foundation

public struct ProviderDiagnosticBatchExport: Codable, Sendable {
    public let schemaVersion: String
    public let timestamp: Date
    public let diagnostics: [ProviderDiagnosticExport]

    public init(
        schemaVersion: String = "1.0",
        timestamp: Date,
        diagnostics: [ProviderDiagnosticExport])
    {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.diagnostics = diagnostics
    }
}

public struct ProviderDiagnosticExport: Codable, Sendable {
    public let schemaVersion: String
    public let timestamp: Date
    public let provider: String
    public let displayName: String
    public let source: String
    public let sourceMode: String
    public let auth: ProviderDiagnosticAuthSummary
    public let usage: ProviderDiagnosticUsageSummary?
    public let fetchAttempts: [ProviderDiagnosticFetchAttempt]
    public let error: ProviderDiagnosticError?
    public let settings: ProviderDiagnosticSettingsSummary
    public let details: ProviderDiagnosticDetails?

    public init(
        schemaVersion: String = "1.0",
        timestamp: Date,
        provider: String,
        displayName: String,
        source: String,
        sourceMode: String,
        auth: ProviderDiagnosticAuthSummary,
        usage: ProviderDiagnosticUsageSummary?,
        fetchAttempts: [ProviderDiagnosticFetchAttempt],
        error: ProviderDiagnosticError?,
        settings: ProviderDiagnosticSettingsSummary,
        details: ProviderDiagnosticDetails?)
    {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.provider = provider
        self.displayName = displayName
        self.source = source
        self.sourceMode = sourceMode
        self.auth = auth
        self.usage = usage
        self.fetchAttempts = fetchAttempts
        self.error = error
        self.settings = settings
        self.details = details
    }
}

public struct ProviderDiagnosticAuthSummary: Codable, Sendable {
    public let configured: Bool
    public let modes: [String]

    public init(configured: Bool, modes: [String]) {
        self.configured = configured
        self.modes = modes
    }

    public func resolved(with outcome: ProviderFetchOutcome) -> ProviderDiagnosticAuthSummary {
        var resolvedModes = self.modes
        if outcome.isSuccess {
            for attempt in outcome.attempts where attempt.wasAvailable {
                let mode = ProviderDiagnosticFetchAttempt.kindLabel(attempt.kind)
                if !resolvedModes.contains(mode) {
                    resolvedModes.append(mode)
                }
            }
        }
        let configured = self.configured || outcome.isSuccess
        return ProviderDiagnosticAuthSummary(configured: configured, modes: resolvedModes)
    }
}

public struct ProviderDiagnosticUsageSummary: Codable, Sendable {
    public let updatedAt: Date
    public let windows: [ProviderDiagnosticRateWindow]
    public let extraWindowCount: Int
    public let providerCostPresent: Bool
    public let providerSpecificData: [String]

    public init(from snapshot: UsageSnapshot) {
        var windows: [ProviderDiagnosticRateWindow] = []
        if let primary = snapshot.primary {
            windows.append(ProviderDiagnosticRateWindow(label: "primary", window: primary))
        }
        if let secondary = snapshot.secondary {
            windows.append(ProviderDiagnosticRateWindow(label: "secondary", window: secondary))
        }
        if let tertiary = snapshot.tertiary {
            windows.append(ProviderDiagnosticRateWindow(label: "tertiary", window: tertiary))
        }
        for extra in snapshot.extraRateWindows ?? [] {
            windows.append(ProviderDiagnosticRateWindow(label: extra.title, window: extra.window))
        }

        var providerSpecificData: [String] = []
        if snapshot.kiroUsage != nil { providerSpecificData.append("kiroUsage") }
        if snapshot.zaiUsage != nil { providerSpecificData.append("zaiUsage") }
        if snapshot.minimaxUsage != nil { providerSpecificData.append("minimaxUsage") }
        if snapshot.deepseekUsage != nil { providerSpecificData.append("deepseekUsage") }
        if snapshot.openRouterUsage != nil { providerSpecificData.append("openRouterUsage") }
        if snapshot.openAIAPIUsage != nil { providerSpecificData.append("openAIAPIUsage") }
        if snapshot.claudeAdminAPIUsage != nil { providerSpecificData.append("claudeAdminAPIUsage") }
        if snapshot.mistralUsage != nil { providerSpecificData.append("mistralUsage") }
        if snapshot.deepgramUsage != nil { providerSpecificData.append("deepgramUsage") }
        if snapshot.cursorRequests != nil { providerSpecificData.append("cursorRequests") }

        self.updatedAt = snapshot.updatedAt
        self.windows = windows
        self.extraWindowCount = snapshot.extraRateWindows?.count ?? 0
        self.providerCostPresent = snapshot.providerCost != nil
        self.providerSpecificData = providerSpecificData.sorted()
    }
}

public struct ProviderDiagnosticRateWindow: Codable, Sendable {
    public let label: String
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let hasResetDescription: Bool
    public let nextRegenPercent: Double?

    public init(label: String, window: RateWindow) {
        self.label = label
        self.usedPercent = window.usedPercent
        self.windowMinutes = window.windowMinutes
        self.resetsAt = window.resetsAt
        self.hasResetDescription = window.resetDescription?.isEmpty == false
        self.nextRegenPercent = window.nextRegenPercent
    }
}

public struct ProviderDiagnosticFetchAttempt: Codable, Sendable {
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
        self.errorCategory = attempt.errorDescription.map(Self.errorCategoryLabel)
    }

    public static func kindLabel(_ kind: ProviderFetchKind) -> String {
        switch kind {
        case .cli: "cli"
        case .web: "web"
        case .oauth: "oauth"
        case .apiToken: "api"
        case .localProbe: "local"
        case .webDashboard: "web"
        }
    }

    public static func errorCategoryLabel(_ description: String?) -> String {
        guard let desc = description?.lowercased() else { return "unknown" }
        if desc.contains("endpoint override") || desc.contains("source") || desc.contains("not supported") ||
            desc.contains("unavailable")
        {
            return "configuration"
        }
        if desc.contains("network") || desc.contains("timeout") || desc.contains("connection") {
            return "network"
        }
        if desc.contains("auth") || desc.contains("credential") || desc.contains("token") || desc.contains("cookie") ||
            desc.contains("api key") || desc.contains("key not configured") || desc.contains("missing key")
        {
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

public struct ProviderDiagnosticError: Codable, Sendable {
    public let category: String
    public let safeDescription: String

    public init(category: String, safeDescription: String) {
        self.category = category
        self.safeDescription = safeDescription
    }

    public init(from error: Error, authConfigured: Bool) {
        self.category = Self.errorCategory(error, authConfigured: authConfigured)
        self.safeDescription = Self.safeDescription(category: self.category)
    }

    private static func errorCategory(_ error: Error, authConfigured: Bool) -> String {
        if case ProviderFetchError.noAvailableStrategy = error {
            return authConfigured ? "configuration" : "auth"
        }
        if let minimaxError = error as? MiniMaxUsageError {
            switch minimaxError {
            case .networkError: return "network"
            case .invalidCredentials: return "auth"
            case .apiError: return "api"
            case .parseFailed: return "parse"
            }
        }
        if let minimaxError = error as? MiniMaxSettingsError {
            switch minimaxError {
            case .invalidEndpointOverride:
                return "configuration"
            case .missingCookie:
                return "auth"
            }
        }
        if error is MiniMaxAPISettingsError { return "auth" }
        if let alibabaError = error as? AlibabaCodingPlanSettingsError {
            switch alibabaError {
            case .invalidEndpointOverride:
                return "configuration"
            case .missingToken, .missingCookie, .invalidCookie:
                return "auth"
            }
        }
        return ProviderDiagnosticFetchAttempt.errorCategoryLabel(error.localizedDescription)
    }

    private static func safeDescription(category: String) -> String {
        switch category {
        case "network":
            "Network error - check your connection"
        case "auth":
            "Authentication or setup issue - check provider credentials"
        case "api":
            "API error - service returned an unexpected response"
        case "parse":
            "Parse error - unexpected response format"
        case "configuration":
            "Configuration issue - check provider source and settings"
        default:
            "An unexpected error occurred"
        }
    }
}

public struct ProviderDiagnosticSettingsSummary: Codable, Sendable {
    public let sourceMode: String
    public let apiRegion: String?

    public init(sourceMode: ProviderSourceMode, apiRegion: String? = nil) {
        self.sourceMode = sourceMode.rawValue
        self.apiRegion = apiRegion
    }
}

public enum ProviderDiagnosticDetails: Codable, Sendable {
    case minimax(MiniMaxDiagnosticDetails)

    private enum CodingKeys: String, CodingKey {
        case type
        case minimax
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "minimax":
            self = try .minimax(container.decode(MiniMaxDiagnosticDetails.self, forKey: .minimax))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown provider diagnostic detail type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .minimax(details):
            try container.encode("minimax", forKey: .type)
            try container.encode(details, forKey: .minimax)
        }
    }
}

public struct MiniMaxDiagnosticDetails: Codable, Sendable {
    public let planName: String?
    public let availablePrompts: Int?
    public let currentPrompts: Int?
    public let remainingPrompts: Int?
    public let windowMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let services: [MiniMaxDiagnosticServiceUsage]?
    public let billingSummaryPresent: Bool

    public init(from snapshot: MiniMaxUsageSnapshot) {
        self.planName = snapshot.planName
        self.availablePrompts = snapshot.availablePrompts
        self.currentPrompts = snapshot.currentPrompts
        self.remainingPrompts = snapshot.remainingPrompts
        self.windowMinutes = snapshot.windowMinutes
        self.usedPercent = snapshot.usedPercent
        self.resetsAt = snapshot.resetsAt
        self.services = snapshot.services?.map { MiniMaxDiagnosticServiceUsage(from: $0) }
        self.billingSummaryPresent = snapshot.billingSummary != nil
    }
}

public struct MiniMaxDiagnosticServiceUsage: Codable, Sendable {
    public let displayName: String
    public let percent: Double
    public let windowType: String
    public let resetsAt: Date?
    public let hasResetDescription: Bool

    public init(from service: MiniMaxServiceUsage) {
        self.displayName = service.displayName
        self.percent = service.percent
        self.windowType = service.windowType
        self.resetsAt = service.resetsAt
        self.hasResetDescription = !service.resetDescription.isEmpty
    }
}

public enum ProviderDiagnosticExportBuilder {
    public struct Input: Sendable {
        public let provider: UsageProvider
        public let descriptor: ProviderDescriptor
        public let outcome: ProviderFetchOutcome
        public let sourceMode: ProviderSourceMode
        public let settings: ProviderSettingsSnapshot?
        public let auth: ProviderDiagnosticAuthSummary

        public init(
            provider: UsageProvider,
            descriptor: ProviderDescriptor,
            outcome: ProviderFetchOutcome,
            sourceMode: ProviderSourceMode,
            settings: ProviderSettingsSnapshot?,
            auth: ProviderDiagnosticAuthSummary)
        {
            self.provider = provider
            self.descriptor = descriptor
            self.outcome = outcome
            self.sourceMode = sourceMode
            self.settings = settings
            self.auth = auth
        }
    }

    public static func build(_ input: Input) -> ProviderDiagnosticExport {
        let resolvedAuth = input.auth.resolved(with: input.outcome)
        let usage = input.outcome.usageSnapshot.map { ProviderDiagnosticUsageSummary(from: $0) }
        let error = input.outcome.failureError
            .map { ProviderDiagnosticError(from: $0, authConfigured: resolvedAuth.configured) }
        let settingsSummary = ProviderDiagnosticSettingsSummary(
            sourceMode: input.sourceMode,
            apiRegion: Self.safeAPIRegion(provider: input.provider, settings: input.settings))

        return ProviderDiagnosticExport(
            timestamp: Date(),
            provider: input.provider.rawValue,
            displayName: input.descriptor.metadata.displayName,
            source: input.outcome.sourceLabel,
            sourceMode: input.sourceMode.rawValue,
            auth: resolvedAuth,
            usage: usage,
            fetchAttempts: input.outcome.attempts.map { ProviderDiagnosticFetchAttempt(from: $0) },
            error: error,
            settings: settingsSummary,
            details: Self.details(provider: input.provider, outcome: input.outcome))
    }

    private static func safeAPIRegion(provider: UsageProvider, settings: ProviderSettingsSnapshot?) -> String? {
        guard provider == .minimax else { return nil }
        return settings?.minimax?.apiRegion.rawValue ?? "global"
    }

    private static func details(provider: UsageProvider, outcome: ProviderFetchOutcome) -> ProviderDiagnosticDetails? {
        guard provider == .minimax,
              let usage = outcome.usageSnapshot?.minimaxUsage
        else {
            return nil
        }
        return .minimax(MiniMaxDiagnosticDetails(from: usage))
    }
}

extension ProviderFetchOutcome {
    fileprivate var isSuccess: Bool {
        guard case .success = self.result else { return false }
        return true
    }

    fileprivate var sourceLabel: String {
        guard case let .success(result) = result else { return "failed" }
        return result.sourceLabel
    }

    fileprivate var usageSnapshot: UsageSnapshot? {
        guard case let .success(result) = result else { return nil }
        return result.usage
    }

    fileprivate var failureError: Error? {
        guard case let .failure(error) = result else { return nil }
        return error
    }
}
