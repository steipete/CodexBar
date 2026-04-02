import Foundation

public struct MistralModelListResponse: Decodable, Sendable {
    public let object: String?
    public let data: [MistralModelCard]

    public init(object: String?, data: [MistralModelCard]) {
        self.object = object
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            self.object = try keyed.decodeIfPresent(String.self, forKey: .object)
            self.data = try keyed.decode([MistralModelCard].self, forKey: .data)
            return
        }

        var unkeyed = try decoder.unkeyedContainer()
        var models: [MistralModelCard] = []
        while !unkeyed.isAtEnd {
            models.append(try unkeyed.decode(MistralModelCard.self))
        }
        self.object = "list"
        self.data = models
    }

    private enum CodingKeys: String, CodingKey {
        case object
        case data
    }
}

public struct MistralModelCard: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let object: String?
    public let created: Int?
    public let ownedBy: String?
    public let capabilities: MistralModelCapabilities
    public let name: String?
    public let description: String?
    public let maxContextLength: Int?
    public let aliases: [String]
    public let deprecation: Date?
    public let deprecationReplacementModel: String?
    public let defaultModelTemperature: Double?
    public let type: String?
    public let job: String?
    public let root: String?
    public let archived: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
        case capabilities
        case name
        case description
        case maxContextLength = "max_context_length"
        case aliases
        case deprecation
        case deprecationReplacementModel = "deprecation_replacement_model"
        case defaultModelTemperature = "default_model_temperature"
        case type
        case job
        case root
        case archived
    }

    public init(
        id: String,
        object: String?,
        created: Int?,
        ownedBy: String?,
        capabilities: MistralModelCapabilities,
        name: String?,
        description: String?,
        maxContextLength: Int?,
        aliases: [String],
        deprecation: Date?,
        deprecationReplacementModel: String?,
        defaultModelTemperature: Double?,
        type: String?,
        job: String?,
        root: String?,
        archived: Bool?)
    {
        self.id = id
        self.object = object
        self.created = created
        self.ownedBy = ownedBy
        self.capabilities = capabilities
        self.name = name
        self.description = description
        self.maxContextLength = maxContextLength
        self.aliases = aliases
        self.deprecation = deprecation
        self.deprecationReplacementModel = deprecationReplacementModel
        self.defaultModelTemperature = defaultModelTemperature
        self.type = type
        self.job = job
        self.root = root
        self.archived = archived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.object = try container.decodeIfPresent(String.self, forKey: .object)
        self.created = try container.decodeIfPresent(Int.self, forKey: .created)
        self.ownedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
        self.capabilities = try container.decodeIfPresent(MistralModelCapabilities.self, forKey: .capabilities)
            ?? MistralModelCapabilities()
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.maxContextLength = try container.decodeIfPresent(Int.self, forKey: .maxContextLength)
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.deprecation = try Self.decodeDate(container: container, key: .deprecation)
        self.deprecationReplacementModel = try container.decodeIfPresent(String.self, forKey: .deprecationReplacementModel)
        self.defaultModelTemperature = try container.decodeIfPresent(Double.self, forKey: .defaultModelTemperature)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.job = try container.decodeIfPresent(String.self, forKey: .job)
        self.root = try container.decodeIfPresent(String.self, forKey: .root)
        self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived)
    }

    public var displayName: String {
        if let name = self.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let root = self.root?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            return root
        }
        return self.id
    }

    public var workspaceOwner: String? {
        guard let ownedBy = self.ownedBy?.trimmingCharacters(in: .whitespacesAndNewlines), !ownedBy.isEmpty else {
            return nil
        }
        if ownedBy == "mistralai" {
            return nil
        }
        return ownedBy
    }

    private static func decodeDate(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys) throws -> Date?
    {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

public struct MistralModelCapabilities: Decodable, Sendable, Equatable {
    public let completionChat: Bool
    public let completionFim: Bool
    public let functionCalling: Bool
    public let fineTuning: Bool
    public let vision: Bool
    public let ocr: Bool
    public let classification: Bool
    public let moderation: Bool
    public let audio: Bool
    public let audioTranscription: Bool

    private enum CodingKeys: String, CodingKey {
        case completionChat = "completion_chat"
        case completionFim = "completion_fim"
        case functionCalling = "function_calling"
        case fineTuning = "fine_tuning"
        case vision
        case ocr
        case classification
        case moderation
        case audio
        case audioTranscription = "audio_transcription"
    }

    public init(
        completionChat: Bool = false,
        completionFim: Bool = false,
        functionCalling: Bool = false,
        fineTuning: Bool = false,
        vision: Bool = false,
        ocr: Bool = false,
        classification: Bool = false,
        moderation: Bool = false,
        audio: Bool = false,
        audioTranscription: Bool = false)
    {
        self.completionChat = completionChat
        self.completionFim = completionFim
        self.functionCalling = functionCalling
        self.fineTuning = fineTuning
        self.vision = vision
        self.ocr = ocr
        self.classification = classification
        self.moderation = moderation
        self.audio = audio
        self.audioTranscription = audioTranscription
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.completionChat = try container.decodeIfPresent(Bool.self, forKey: .completionChat) ?? false
        self.completionFim = try container.decodeIfPresent(Bool.self, forKey: .completionFim) ?? false
        self.functionCalling = try container.decodeIfPresent(Bool.self, forKey: .functionCalling) ?? false
        self.fineTuning = try container.decodeIfPresent(Bool.self, forKey: .fineTuning) ?? false
        self.vision = try container.decodeIfPresent(Bool.self, forKey: .vision) ?? false
        self.ocr = try container.decodeIfPresent(Bool.self, forKey: .ocr) ?? false
        self.classification = try container.decodeIfPresent(Bool.self, forKey: .classification) ?? false
        self.moderation = try container.decodeIfPresent(Bool.self, forKey: .moderation) ?? false
        self.audio = try container.decodeIfPresent(Bool.self, forKey: .audio) ?? false
        self.audioTranscription = try container.decodeIfPresent(Bool.self, forKey: .audioTranscription) ?? false
    }
}

public struct MistralRateLimitWindow: Codable, Sendable, Equatable {
    public let kind: String
    public let limit: Int?
    public let remaining: Int?
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(
        kind: String,
        limit: Int?,
        remaining: Int?,
        resetsAt: Date?,
        resetDescription: String?)
    {
        self.kind = kind
        self.limit = limit
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var usedPercent: Double? {
        guard let limit, limit > 0, let remaining else { return nil }
        let used = max(0, limit - remaining)
        return min(100, max(0, (Double(used) / Double(limit)) * 100))
    }

    public func asRateWindow() -> RateWindow? {
        guard let usedPercent else { return nil }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: self.resetsAt,
            resetDescription: self.resetDescription)
    }
}

public struct MistralRateLimitSnapshot: Codable, Sendable, Equatable {
    public let requests: MistralRateLimitWindow?
    public let tokens: MistralRateLimitWindow?
    public let retryAfter: Date?

    public init(requests: MistralRateLimitWindow?, tokens: MistralRateLimitWindow?, retryAfter: Date?) {
        self.requests = requests
        self.tokens = tokens
        self.retryAfter = retryAfter
    }

    public var orderedWindows: [MistralRateLimitWindow] {
        [self.requests, self.tokens].compactMap(\.self)
    }
}

public struct MistralBillingResponse: Codable, Sendable, Equatable {
    public let completion: MistralModelUsageCategory?
    public let ocr: MistralModelUsageCategory?
    public let connectors: MistralModelUsageCategory?
    public let librariesApi: MistralLibrariesUsageCategory?
    public let fineTuning: MistralFineTuningCategory?
    public let audio: MistralModelUsageCategory?
    public let vibeUsage: Double?
    public let date: String?
    public let previousMonth: String?
    public let nextMonth: String?
    public let startDate: String?
    public let endDate: String?
    public let currency: String?
    public let currencySymbol: String?
    public let prices: [MistralPrice]?

    enum CodingKeys: String, CodingKey {
        case completion
        case ocr
        case connectors
        case librariesApi = "libraries_api"
        case fineTuning = "fine_tuning"
        case audio
        case vibeUsage = "vibe_usage"
        case date
        case previousMonth = "previous_month"
        case nextMonth = "next_month"
        case startDate = "start_date"
        case endDate = "end_date"
        case currency
        case currencySymbol = "currency_symbol"
        case prices
    }
}

public struct MistralModelUsageCategory: Codable, Sendable, Equatable {
    public let models: [String: MistralModelUsageData]?

    public init(models: [String: MistralModelUsageData]?) {
        self.models = models
    }
}

public struct MistralLibrariesUsageCategory: Codable, Sendable, Equatable {
    public let pages: MistralModelUsageCategory?
    public let tokens: MistralModelUsageCategory?

    public init(pages: MistralModelUsageCategory?, tokens: MistralModelUsageCategory?) {
        self.pages = pages
        self.tokens = tokens
    }
}

public struct MistralFineTuningCategory: Codable, Sendable, Equatable {
    public let training: [String: MistralModelUsageData]?
    public let storage: [String: MistralModelUsageData]?

    public init(training: [String: MistralModelUsageData]?, storage: [String: MistralModelUsageData]?) {
        self.training = training
        self.storage = storage
    }
}

public struct MistralModelUsageData: Codable, Sendable, Equatable {
    public let input: [MistralUsageEntry]?
    public let output: [MistralUsageEntry]?
    public let cached: [MistralUsageEntry]?

    public init(input: [MistralUsageEntry]?, output: [MistralUsageEntry]?, cached: [MistralUsageEntry]?) {
        self.input = input
        self.output = output
        self.cached = cached
    }
}

public struct MistralUsageEntry: Codable, Sendable, Equatable {
    public let usageType: String?
    public let eventType: String?
    public let billingMetric: String?
    public let billingDisplayName: String?
    public let billingGroup: String?
    public let timestamp: String?
    public let value: Double?
    public let valuePaid: Double?

    enum CodingKeys: String, CodingKey {
        case usageType = "usage_type"
        case eventType = "event_type"
        case billingMetric = "billing_metric"
        case billingDisplayName = "billing_display_name"
        case billingGroup = "billing_group"
        case timestamp
        case value
        case valuePaid = "value_paid"
    }
}

public struct MistralPrice: Codable, Sendable, Equatable {
    public let eventType: String?
    public let billingMetric: String?
    public let billingGroup: String?
    public let price: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case billingMetric = "billing_metric"
        case billingGroup = "billing_group"
        case price
    }
}

public struct MistralWorkspaceUsageSnapshot: Codable, Sendable, Equatable {
    public let name: String
    public let totalCost: Double
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCachedTokens: Int
    public let modelCount: Int

    public init(
        name: String,
        totalCost: Double,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCachedTokens: Int,
        modelCount: Int)
    {
        self.name = name
        self.totalCost = totalCost
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCachedTokens = totalCachedTokens
        self.modelCount = modelCount
    }
}

public struct MistralUsageSummarySnapshot: Codable, Sendable, Equatable {
    public enum SourceKind: String, Codable, Sendable {
        case web
        case api
    }

    public let sourceKind: SourceKind
    public let modelCount: Int
    public let previewModelNames: String?
    public let workspaceSummary: String?
    public let totalCost: Double?
    public let currencyCode: String?
    public let currencySymbol: String?
    public let totalInputTokens: Int?
    public let totalOutputTokens: Int?
    public let totalCachedTokens: Int?
    public let periodStart: Date?
    public let periodEnd: Date?
    public let workspaces: [MistralWorkspaceUsageSnapshot]
    public let updatedAt: Date

    public init(
        sourceKind: SourceKind,
        modelCount: Int,
        previewModelNames: String?,
        workspaceSummary: String?,
        totalCost: Double?,
        currencyCode: String?,
        currencySymbol: String?,
        totalInputTokens: Int?,
        totalOutputTokens: Int?,
        totalCachedTokens: Int?,
        periodStart: Date?,
        periodEnd: Date?,
        workspaces: [MistralWorkspaceUsageSnapshot] = [],
        updatedAt: Date)
    {
        self.sourceKind = sourceKind
        self.modelCount = modelCount
        self.previewModelNames = previewModelNames
        self.workspaceSummary = workspaceSummary
        self.totalCost = totalCost
        self.currencyCode = currencyCode
        self.currencySymbol = currencySymbol
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCachedTokens = totalCachedTokens
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.workspaces = workspaces
        self.updatedAt = updatedAt
    }

    public var totalTokens: Int? {
        guard let totalInputTokens, let totalOutputTokens else { return nil }
        return totalInputTokens + totalOutputTokens + (totalCachedTokens ?? 0)
    }

    public var billingPeriodLabel: String? {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateFormat = "LLLL yyyy"
        if let periodStart {
            return formatter.string(from: periodStart)
        }
        if let periodEnd {
            return formatter.string(from: periodEnd)
        }
        return nil
    }

    public var resetsAt: Date? {
        guard let periodEnd else { return nil }
        return Calendar.autoupdatingCurrent.date(byAdding: .second, value: 1, to: periodEnd) ?? periodEnd
    }

    public var tokenSummaryLine: String? {
        guard let totalInputTokens, let totalOutputTokens else { return nil }
        var parts = [
            "In: \(UsageFormatter.tokenCountString(totalInputTokens))",
            "Out: \(UsageFormatter.tokenCountString(totalOutputTokens))",
        ]
        if let totalCachedTokens, totalCachedTokens > 0 {
            parts.append("Cached: \(UsageFormatter.tokenCountString(totalCachedTokens))")
        }
        return parts.joined(separator: " · ")
    }

    public var workspaceLine: String? {
        if !self.workspaces.isEmpty {
            let names = self.workspaces.map(\.name)
            let preview = names.prefix(2).joined(separator: ", ")
            if names.count > 2 {
                return "\(preview) + \(names.count - 2) more workspaces"
            }
            return preview
        }
        return self.workspaceSummary
    }

    public var modelsLine: String? {
        switch self.sourceKind {
        case .web:
            guard self.modelCount > 0 else { return nil }
            return "\(self.modelCount) billed models"
        case .api:
            guard self.modelCount > 0 else { return nil }
            return "\(self.modelCount) models available"
        }
    }
}

public struct MistralAPIUsageSnapshot: Sendable, Equatable {
    public let models: [MistralModelCard]
    public let rateLimits: MistralRateLimitSnapshot?
    public let updatedAt: Date

    public init(models: [MistralModelCard], rateLimits: MistralRateLimitSnapshot?, updatedAt: Date) {
        self.models = models
        self.rateLimits = rateLimits
        self.updatedAt = updatedAt
    }

    public var modelCount: Int {
        self.models.count
    }

    public var accessibleModelNames: [String] {
        var seen: Set<String> = []
        return self.models
            .map(\.displayName)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
    }

    public var previewModelNames: String? {
        let names = Array(self.accessibleModelNames.prefix(3))
        guard !names.isEmpty else { return nil }
        if self.accessibleModelNames.count > names.count {
            return names.joined(separator: ", ") + " + \(self.accessibleModelNames.count - names.count) more"
        }
        return names.joined(separator: ", ")
    }

    public var workspaceNames: [String] {
        var seen: Set<String> = []
        return self.models
            .compactMap(\.workspaceOwner)
            .filter { seen.insert($0).inserted }
    }

    public var workspaceSummary: String? {
        switch self.workspaceNames.count {
        case 0:
            return nil
        case 1:
            return self.workspaceNames.first
        default:
            return "\(self.workspaceNames.count) workspaces"
        }
    }

    public var loginSummary: String? {
        if self.modelCount > 0 {
            return "\(self.modelCount) models"
        }
        return "Connected"
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let windows = self.rateLimits?.orderedWindows ?? []
        let primary = windows.first?.asRateWindow()
        let secondary = windows.dropFirst().first?.asRateWindow()
        let summary = MistralUsageSummarySnapshot(
            sourceKind: .api,
            modelCount: self.modelCount,
            previewModelNames: self.previewModelNames,
            workspaceSummary: self.workspaceSummary,
            totalCost: nil,
            currencyCode: nil,
            currencySymbol: nil,
            totalInputTokens: nil,
            totalOutputTokens: nil,
            totalCachedTokens: nil,
            periodStart: nil,
            periodEnd: nil,
            workspaces: [],
            updatedAt: self.updatedAt)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            mistralUsage: summary,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .mistral,
                accountEmail: nil,
                accountOrganization: self.workspaceSummary,
                loginMethod: self.loginSummary))
    }
}

public struct MistralBillingUsageSnapshot: Sendable, Equatable {
    public let totalCost: Double
    public let currency: String
    public let currencySymbol: String
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCachedTokens: Int
    public let modelCount: Int
    public let startDate: Date?
    public let endDate: Date?
    public let workspaces: [MistralWorkspaceUsageSnapshot]
    public let updatedAt: Date

    public init(
        totalCost: Double,
        currency: String,
        currencySymbol: String,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCachedTokens: Int,
        modelCount: Int,
        startDate: Date?,
        endDate: Date?,
        workspaces: [MistralWorkspaceUsageSnapshot],
        updatedAt: Date)
    {
        self.totalCost = totalCost
        self.currency = currency
        self.currencySymbol = currencySymbol
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCachedTokens = totalCachedTokens
        self.modelCount = modelCount
        self.startDate = startDate
        self.endDate = endDate
        self.workspaces = workspaces
        self.updatedAt = updatedAt
    }

    public var workspaceSummary: String? {
        switch self.workspaces.count {
        case 0:
            return nil
        case 1:
            return self.workspaces.first?.name
        default:
            return "\(self.workspaces.count) workspaces"
        }
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let resetDate = self.endDate.map { Calendar.autoupdatingCurrent.date(byAdding: .second, value: 1, to: $0) ?? $0 }
        let summary = MistralUsageSummarySnapshot(
            sourceKind: .web,
            modelCount: self.modelCount,
            previewModelNames: nil,
            workspaceSummary: self.workspaceSummary,
            totalCost: self.totalCost,
            currencyCode: self.currency,
            currencySymbol: self.currencySymbol,
            totalInputTokens: self.totalInputTokens,
            totalOutputTokens: self.totalOutputTokens,
            totalCachedTokens: self.totalCachedTokens,
            periodStart: self.startDate,
            periodEnd: self.endDate,
            workspaces: self.workspaces,
            updatedAt: self.updatedAt)

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.totalCost,
                limit: 0,
                currencyCode: self.currency,
                period: summary.billingPeriodLabel ?? "Current month",
                resetsAt: resetDate,
                updatedAt: self.updatedAt),
            mistralUsage: summary,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .mistral,
                accountEmail: nil,
                accountOrganization: self.workspaceSummary,
                loginMethod: summary.billingPeriodLabel ?? "Current month"))
    }
}

public enum MistralUsageError: LocalizedError, Sendable, Equatable {
    case missingToken
    case missingCookie
    case invalidCookie
    case unauthorized
    case invalidCredentials
    case rateLimited(retryAfter: Date?)
    case unexpectedStatus(code: Int, body: String?)
    case invalidResponse
    case networkError(String)
    case decodeFailed(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Mistral API key missing. Set MISTRAL_API_KEY or configure the key in CodexBar settings."
        case .missingCookie:
            return "No Mistral AI Studio session cookies found. Sign into console.mistral.ai or paste a Cookie header."
        case .invalidCookie:
            return "Mistral cookie header is invalid. It must include an ory_session_* cookie."
        case .unauthorized:
            return "Mistral authentication failed (401/403). Check the API key in console.mistral.ai."
        case .invalidCredentials:
            return "Mistral AI Studio session expired or is no longer valid. Refresh your cookies and try again."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return "Mistral API rate limited. Try again after \(Self.formatDate(retryAfter))."
            }
            return "Mistral API rate limited. Try again later."
        case let .unexpectedStatus(code, body):
            if let body, !body.isEmpty {
                return "Mistral request failed (HTTP \(code)): \(body)"
            }
            return "Mistral request failed (HTTP \(code))."
        case .invalidResponse:
            return "Mistral returned an invalid response."
        case let .networkError(message):
            return "Mistral network error: \(message)"
        case let .decodeFailed(message):
            return "Mistral response could not be decoded: \(message)"
        case let .parseFailed(message):
            return "Mistral billing response could not be parsed: \(message)"
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

public enum MistralSettingsError: LocalizedError, Sendable, Equatable {
    case missingCookie
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            return "No Mistral session cookies found in browsers."
        case .invalidCookie:
            return "Mistral cookie header is invalid or missing an ory_session_* cookie."
        }
    }
}
