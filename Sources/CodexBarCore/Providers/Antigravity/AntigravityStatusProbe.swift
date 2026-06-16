import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AntigravityModelQuota: Sendable {
    public let label: String
    public let modelId: String
    public let remainingFraction: Double?
    public let resetTime: Date?
    public let resetDescription: String?

    public init(
        label: String,
        modelId: String,
        remainingFraction: Double?,
        resetTime: Date?,
        resetDescription: String?)
    {
        self.label = label
        self.modelId = modelId
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double {
        guard let remainingFraction else { return 0 }
        return max(0, min(100, remainingFraction * 100))
    }
}

private enum AntigravityModelFamily {
    case claude
    case gpt
    case geminiPro
    case geminiFlash
    case unknown
}

private enum AntigravityUsagePool: Hashable {
    case gemini
    case claudeGPT

    var id: String {
        switch self {
        case .gemini: "antigravity-gemini"
        case .claudeGPT: "antigravity-claude-gpt"
        }
    }

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .claudeGPT: "Claude + GPT"
        }
    }

    var sortRank: Int {
        switch self {
        case .gemini: 0
        case .claudeGPT: 1
        }
    }
}

private struct AntigravityModelVersion: Comparable {
    let major: Int
    let minor: Int

    static func < (lhs: AntigravityModelVersion, rhs: AntigravityModelVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}

private struct AntigravityNormalizedModel {
    let quota: AntigravityModelQuota
    let family: AntigravityModelFamily
    let selectionPriority: Int?
    let isImage: Bool
    let isLite: Bool
    let isAutocomplete: Bool
    let version: AntigravityModelVersion?
    let tier: Int
}

public enum AntigravityModelQuotaSource: Sendable {
    case local
    case remote
}

public struct AntigravityStatusSnapshot: Sendable {
    public let modelQuotas: [AntigravityModelQuota]
    public let accountEmail: String?
    public let accountPlan: String?
    public let source: AntigravityModelQuotaSource
    let quotaSummary: AntigravityQuotaSummary?

    public init(
        modelQuotas: [AntigravityModelQuota],
        accountEmail: String?,
        accountPlan: String?,
        source: AntigravityModelQuotaSource = .remote)
    {
        self.modelQuotas = modelQuotas
        self.accountEmail = accountEmail
        self.accountPlan = accountPlan
        self.source = source
        self.quotaSummary = nil
    }

    init(
        quotaSummary: AntigravityQuotaSummary,
        accountEmail: String?,
        accountPlan: String?,
        source: AntigravityModelQuotaSource = .local)
    {
        self.modelQuotas = []
        self.accountEmail = accountEmail
        self.accountPlan = accountPlan
        self.source = source
        self.quotaSummary = quotaSummary
    }

    public func toUsageSnapshot() throws -> UsageSnapshot {
        if let quotaSummary {
            return try Self.usageSnapshot(
                from: quotaSummary,
                accountEmail: self.accountEmail,
                accountPlan: self.accountPlan)
        }

        guard !self.modelQuotas.isEmpty else {
            throw AntigravityStatusProbeError.parseFailed("No quota models available")
        }

        let normalized = Self.normalizedModels(self.modelQuotas)
        let summaryCandidates = normalized.filter(Self.isSummaryCandidate)
        let primaryQuota = Self.representative(for: .gemini, in: summaryCandidates)
        let secondaryQuota = Self.representative(for: .claudeGPT, in: summaryCandidates)
        let fallbackQuota: AntigravityModelQuota? = if primaryQuota == nil, secondaryQuota == nil {
            switch self.source {
            case .local:
                Self.fallbackRepresentative(in: normalized.filter {
                    $0.family == .unknown &&
                        Self.isSelectableTextModel($0) &&
                        $0.quota.remainingFraction != nil
                })
            case .remote:
                nil
            }
        } else {
            nil
        }

        let primary = primaryQuota.map(Self.rateWindow(for:))
        let secondary = secondaryQuota.map(Self.rateWindow(for:))
        let extraWindows = Self.extraRateWindows(
            from: normalized,
            summaryCandidates: summaryCandidates,
            compactFallbackModelID: fallbackQuota?.modelId,
            representedPools: Set([
                primaryQuota.map { _ in AntigravityUsagePool.gemini },
                secondaryQuota.map { _ in AntigravityUsagePool.claudeGPT },
            ].compactMap(\.self)))

        let identity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.accountPlan)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: extraWindows.isEmpty ? nil : extraWindows,
            updatedAt: Date(),
            identity: identity)
    }

    func withIdentity(from snapshot: AntigravityStatusSnapshot?) -> AntigravityStatusSnapshot {
        guard let snapshot else { return self }
        let accountEmail = snapshot.accountEmail ?? self.accountEmail
        let accountPlan = snapshot.accountPlan ?? self.accountPlan
        if let quotaSummary {
            return AntigravityStatusSnapshot(
                quotaSummary: quotaSummary,
                accountEmail: accountEmail,
                accountPlan: accountPlan,
                source: self.source)
        }
        return AntigravityStatusSnapshot(
            modelQuotas: self.modelQuotas,
            accountEmail: accountEmail,
            accountPlan: accountPlan,
            source: self.source)
    }

    private static func usageSnapshot(
        from quotaSummary: AntigravityQuotaSummary,
        accountEmail: String?,
        accountPlan: String?) throws -> UsageSnapshot
    {
        let namedWindows = Self.quotaSummaryWindows(from: quotaSummary)
        guard !namedWindows.isEmpty else {
            throw AntigravityStatusProbeError.parseFailed("No quota buckets available")
        }

        let primary = Self.quotaSummaryRepresentative(title: "Gemini", in: namedWindows)
        let secondary = Self.quotaSummaryRepresentative(title: "Claude + GPT", in: namedWindows)

        let identity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: accountEmail,
            accountOrganization: nil,
            loginMethod: accountPlan)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: namedWindows,
            updatedAt: Date(),
            identity: identity)
    }

    private static func quotaSummaryRepresentative(
        title: String,
        in windows: [NamedRateWindow]) -> RateWindow?
    {
        windows
            .filter { $0.usageKnown && $0.title.hasPrefix("\(title) ") }
            .max { lhs, rhs in
                if lhs.window.usedPercent != rhs.window.usedPercent {
                    return lhs.window.usedPercent < rhs.window.usedPercent
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }?
            .window
    }

    private static func quotaSummaryWindows(from quotaSummary: AntigravityQuotaSummary) -> [NamedRateWindow] {
        let sortedGroups = quotaSummary.groups.enumerated().sorted { lhs, rhs in
            let lhsRank = Self.quotaGroupSortRank(lhs.element)
            let rhsRank = Self.quotaGroupSortRank(rhs.element)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return sortedGroups.flatMap { group in
            let groupTitle = Self.displayTitle(forQuotaGroup: group)
            let sortedBuckets = group.buckets.enumerated().sorted { lhs, rhs in
                let lhsRank = Self.quotaBucketSortRank(lhs.element)
                let rhsRank = Self.quotaBucketSortRank(rhs.element)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.offset < rhs.offset
            }.map(\.element)

            return sortedBuckets.map { bucket in
                let bucketTitle = Self.displayTitle(forQuotaBucket: bucket)
                let remainingPercent = Self.remainingPercent(from: bucket.remainingFraction)
                let usedPercent = remainingPercent.map { 100 - $0 } ?? 0
                let window = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: Self.windowMinutes(forQuotaBucket: bucket),
                    resetsAt: bucket.resetTime,
                    resetDescription: bucket.resetDescription)
                return NamedRateWindow(
                    id: Self.quotaSummaryWindowID(for: bucket),
                    title: "\(groupTitle) \(bucketTitle)",
                    window: window,
                    usageKnown: !bucket.disabled && bucket.remainingFraction != nil)
            }
        }
    }

    static func isQuotaSummaryWindowID(_ id: String) -> Bool {
        id.hasPrefix(self.quotaSummaryWindowIDPrefix)
    }

    private static let quotaSummaryWindowIDPrefix = "antigravity-quota-summary-"

    private static func quotaSummaryWindowID(for bucket: AntigravityQuotaSummaryBucket) -> String {
        self.quotaSummaryWindowIDPrefix + bucket.bucketId
    }

    private static func remainingPercent(from remainingFraction: Double?) -> Double? {
        guard let remainingFraction else { return nil }
        return max(0, min(100, remainingFraction * 100))
    }

    private static func displayTitle(forQuotaGroup group: AntigravityQuotaSummaryGroup) -> String {
        let title = group.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        if lower.contains("gemini") {
            return "Gemini"
        }
        if lower.contains("claude") || lower.contains("gpt") {
            return "Claude + GPT"
        }
        let stripped = title.replacingOccurrences(
            of: #"(?i)\s+models?$"#,
            with: "",
            options: .regularExpression)
        return stripped.isEmpty ? title : stripped
    }

    private static func displayTitle(forQuotaBucket bucket: AntigravityQuotaSummaryBucket) -> String {
        switch self.quotaBucketKind(for: bucket) {
        case .session:
            "Session"
        case .weekly:
            "Weekly"
        case .other:
            bucket.displayName
        }
    }

    private static func windowMinutes(forQuotaBucket bucket: AntigravityQuotaSummaryBucket) -> Int? {
        switch self.quotaBucketKind(for: bucket) {
        case .session:
            300
        case .weekly:
            10080
        case .other:
            nil
        }
    }

    private enum QuotaBucketKind {
        case session
        case weekly
        case other
    }

    private static func quotaGroupSortRank(_ group: AntigravityQuotaSummaryGroup) -> Int {
        let title = group.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.contains("gemini") {
            return 0
        }
        if title.contains("claude") || title.contains("gpt") {
            return 1
        }
        return 2
    }

    private static func quotaBucketSortRank(_ bucket: AntigravityQuotaSummaryBucket) -> Int {
        switch self.quotaBucketKind(for: bucket) {
        case .session:
            0
        case .weekly:
            1
        case .other:
            2
        }
    }

    private static func quotaBucketKind(for bucket: AntigravityQuotaSummaryBucket) -> QuotaBucketKind {
        let combined = "\(bucket.bucketId) \(bucket.displayName)".lowercased()
        if combined.contains("5h") || combined.contains("5-hour") || combined.contains("five hour") {
            return .session
        }
        if combined.contains("weekly") {
            return .weekly
        }
        return .other
    }

    private static func rateWindow(for quota: AntigravityModelQuota) -> RateWindow {
        RateWindow(
            usedPercent: 100 - quota.remainingPercent,
            windowMinutes: nil,
            resetsAt: quota.resetTime,
            resetDescription: quota.resetDescription)
    }

    private static func modelOrderPrecedes(
        _ lhs: AntigravityNormalizedModel,
        _ rhs: AntigravityNormalizedModel) -> Bool
    {
        // 1. Family rank: claude=0, geminiPro=1, geminiFlash=2, unknown=3
        let lhsFamilyRank = Self.familyRank(lhs.family)
        let rhsFamilyRank = Self.familyRank(rhs.family)
        if lhsFamilyRank != rhsFamilyRank {
            return lhsFamilyRank < rhsFamilyRank
        }

        // 2. Version descending (newer first); nil version sorts after non-nil
        switch (lhs.version, rhs.version) {
        case let (.some(lv), .some(rv)):
            if lv != rv {
                return lv > rv
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }

        // 3. Tier ascending: High(0) < Medium(1) < Low(2)
        if lhs.tier != rhs.tier {
            return lhs.tier < rhs.tier
        }

        // 4. Label tiebreaker
        return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
    }

    private static func familyRank(_ family: AntigravityModelFamily) -> Int {
        switch family {
        case .claude: 0
        case .gpt: 1
        case .geminiPro: 2
        case .geminiFlash: 3
        case .unknown: 4
        }
    }

    private static func isSummaryCandidate(_ model: AntigravityNormalizedModel) -> Bool {
        self.usagePool(for: model) != nil && self.isSelectableTextModel(model)
    }

    private static func isSelectableTextModel(_ model: AntigravityNormalizedModel) -> Bool {
        !model.isLite && !model.isAutocomplete && !model.isImage
    }

    private static func normalizedModels(_ models: [AntigravityModelQuota]) -> [AntigravityNormalizedModel] {
        models.map { self.normalizeModel($0) }
    }

    private static func normalizeModel(_ quota: AntigravityModelQuota) -> AntigravityNormalizedModel {
        let modelId = quota.modelId.lowercased()
        let label = quota.label.lowercased()
        let family = Self.family(forModelID: modelId, label: label)

        let isLite = modelId.contains("lite") || label.contains("lite")
        let isAutocomplete = modelId.contains("autocomplete") || label.contains("autocomplete") || modelId
            .hasPrefix("tab_")
        let isImage = modelId.contains("image") || label.contains("image")
        let isSelectableTextModel = !isLite && !isAutocomplete && !isImage
        let isLowPriorityGeminiPro = modelId.contains("pro-low")
            || (label.contains("pro") && label.contains("low"))

        let selectionPriority: Int? = switch family {
        case .claude, .gpt:
            0
        case .geminiPro:
            if isLowPriorityGeminiPro, isSelectableTextModel {
                0
            } else if isSelectableTextModel {
                1
            } else {
                nil
            }
        case .geminiFlash:
            isSelectableTextModel ? 0 : nil
        case .unknown:
            nil
        }

        let version = Self.parseVersion(from: label)
        let tier = Self.parseTier(from: label, modelId: modelId)

        return AntigravityNormalizedModel(
            quota: quota,
            family: family,
            selectionPriority: selectionPriority,
            isImage: isImage,
            isLite: isLite,
            isAutocomplete: isAutocomplete,
            version: version,
            tier: tier)
    }

    private static func parseVersion(from label: String) -> AntigravityModelVersion? {
        // Accept either "." or "-" between major and minor so a raw model id used as the
        // label when displayName is missing (e.g. "gemini-3-1-pro-low") still parses 3.1.
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)(?:[.\-](\d+))?"#) else { return nil }
        let nsLabel = label as NSString
        let range = NSRange(location: 0, length: nsLabel.length)
        guard let match = regex.firstMatch(in: label, options: [], range: range) else { return nil }
        let majorRange = Range(match.range(at: 1), in: label)
        guard let majorRange, let major = Int(label[majorRange]) else { return nil }
        let minor: Int = if match.range(at: 2).location != NSNotFound,
                            let minorRange = Range(match.range(at: 2), in: label),
                            let parsed = Int(label[minorRange])
        {
            parsed
        } else {
            0
        }
        return AntigravityModelVersion(major: major, minor: minor)
    }

    private static func parseTier(from label: String, modelId: String) -> Int {
        let combined = label + " " + modelId
        if combined.contains("high") { return 0 }
        if combined.contains("medium") { return 1 }
        if combined.contains("low") { return 2 }
        return 1
    }

    private static func representative(
        for pool: AntigravityUsagePool,
        in models: [AntigravityNormalizedModel]) -> AntigravityModelQuota?
    {
        let candidates = models.filter {
            Self.usagePool(for: $0) == pool && $0.quota.remainingFraction != nil
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            if lhs.quota.remainingPercent != rhs.quota.remainingPercent {
                return lhs.quota.remainingPercent < rhs.quota.remainingPercent
            }
            switch (lhs.quota.resetTime, rhs.quota.resetTime) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
            }
        }?.quota
    }

    private static func fallbackRepresentative(in models: [AntigravityNormalizedModel]) -> AntigravityModelQuota? {
        models.min { lhs, rhs in
            if lhs.quota.remainingPercent != rhs.quota.remainingPercent {
                return lhs.quota.remainingPercent < rhs.quota.remainingPercent
            }
            return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
        }?.quota
    }

    private static func extraRateWindows(
        from models: [AntigravityNormalizedModel],
        summaryCandidates: [AntigravityNormalizedModel],
        compactFallbackModelID: String?,
        representedPools: Set<AntigravityUsagePool>) -> [NamedRateWindow]
    {
        let resetOnlyPoolWindows = [AntigravityUsagePool.gemini, .claudeGPT].compactMap { pool -> NamedRateWindow? in
            guard !representedPools.contains(pool) else { return nil }
            let candidates = summaryCandidates.filter { Self.usagePool(for: $0) == pool }
            guard let resetOnly = candidates.first(where: { model in
                model.quota.remainingFraction == nil &&
                    (model.quota.resetTime != nil || model.quota.resetDescription != nil)
            }) else {
                return nil
            }
            return NamedRateWindow(
                id: pool.id,
                title: pool.title,
                window: Self.rateWindow(for: resetOnly.quota),
                usageKnown: false)
        }

        let distinctWindows = models
            .filter {
                $0.quota.modelId == compactFallbackModelID || Self.shouldShowDistinctExtraWindow($0)
            }
            .sorted(by: Self.modelOrderPrecedes)
            .map { m in
                NamedRateWindow(
                    id: m.quota.modelId == compactFallbackModelID
                        ? Self.compactFallbackWindowID(modelID: m.quota.modelId)
                        : m.quota.modelId,
                    title: m.quota.label,
                    window: Self.rateWindow(for: m.quota),
                    usageKnown: m.quota.remainingFraction != nil)
            }

        return resetOnlyPoolWindows.sorted { lhs, rhs in
            guard let lhsPool = Self.pool(forExtraWindowID: lhs.id),
                  let rhsPool = Self.pool(forExtraWindowID: rhs.id)
            else {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhsPool.sortRank < rhsPool.sortRank
        } + distinctWindows
    }

    private static func compactFallbackWindowID(modelID: String) -> String {
        "antigravity-compact-fallback-\(modelID)"
    }

    private static func shouldShowDistinctExtraWindow(_ model: AntigravityNormalizedModel) -> Bool {
        guard !self.isSummaryCandidate(model) else { return false }
        if model.quota.remainingFraction == nil {
            return model.quota.resetTime != nil || model.quota.resetDescription != nil
        }
        return model.quota.remainingPercent < 99.9
    }

    private static func pool(forExtraWindowID id: String) -> AntigravityUsagePool? {
        switch id {
        case AntigravityUsagePool.gemini.id: .gemini
        case AntigravityUsagePool.claudeGPT.id: .claudeGPT
        default: nil
        }
    }

    private static func usagePool(for model: AntigravityNormalizedModel) -> AntigravityUsagePool? {
        switch model.family {
        case .geminiPro, .geminiFlash:
            .gemini
        case .claude, .gpt:
            .claudeGPT
        case .unknown:
            nil
        }
    }

    private static func family(forModelID modelId: String, label: String) -> AntigravityModelFamily {
        let modelIDFamily = Self.family(from: modelId)
        if modelIDFamily != .unknown {
            return modelIDFamily
        }
        return Self.family(from: label)
    }

    private static func family(from text: String) -> AntigravityModelFamily {
        if text.contains("claude") {
            return .claude
        }
        if text.contains("gpt") || text.contains("openai") {
            return .gpt
        }
        if text.contains("gemini"), text.contains("pro") {
            return .geminiPro
        }
        if text.contains("gemini"), text.contains("flash") {
            return .geminiFlash
        }
        return .unknown
    }
}

public struct AntigravityPlanInfoSummary: Sendable, Codable, Equatable {
    public let planName: String?
    public let planDisplayName: String?
    public let displayName: String?
    public let productName: String?
    public let planShortName: String?
}

public enum AntigravityStatusProbeError: LocalizedError, Sendable, Equatable {
    case notRunning
    case missingCSRFToken
    case portDetectionFailed(String)
    case apiError(String)
    case parseFailed(String)
    case timedOut
    case authenticationRequired
    case accountMismatch(expected: String?, found: String?)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            "Antigravity language server not detected. Launch Antigravity and retry."
        case .missingCSRFToken:
            "Antigravity CSRF token not found. Restart Antigravity and retry."
        case let .portDetectionFailed(message):
            Self.portDetectionDescription(message)
        case let .apiError(message):
            Self.apiErrorDescription(message)
        case let .parseFailed(message):
            "Could not parse Antigravity quota: \(message)"
        case .timedOut:
            "Antigravity quota request timed out."
        case .authenticationRequired:
            "Antigravity CLI is signed out. Run agy in a terminal to sign in, then retry."
        case let .accountMismatch(expected, found):
            Self.accountMismatchDescription(expected: expected, found: found)
        }
    }

    private static func accountMismatchDescription(expected: String?, found: String?) -> String {
        let selected = expected ?? "the selected account"
        if let found {
            return "Antigravity local session is signed in as \(found), not \(selected); "
                + "using the selected account's OAuth data instead."
        }
        return "Antigravity local session did not report an account matching \(selected); "
            + "using the selected account's OAuth data instead."
    }

    private static func portDetectionDescription(_ message: String) -> String {
        switch message {
        case "lsof not available":
            "Antigravity port detection needs lsof. Install it, then retry."
        case "no listening ports found":
            "Antigravity is running but not exposing ports yet. Try again in a few seconds."
        default:
            "Antigravity port detection failed: \(message)"
        }
    }

    private static func apiErrorDescription(_ message: String) -> String {
        if message.contains("HTTP 401") || message.contains("HTTP 403") {
            return "Antigravity session expired. Restart Antigravity and retry."
        }
        return "Antigravity API error: \(message)"
    }
}

public struct AntigravityStatusProbe: Sendable {
    /// Which local Antigravity processes the probe may attach to.
    public enum ProcessScope: Sendable {
        /// Match Antigravity app, Antigravity IDE, and the `agy` CLI language server.
        case ideAndCLI
        /// Match only the Antigravity 2.0 app language server.
        case appOnly
        /// Match only the Antigravity IDE extension language server.
        case ideOnly
    }

    public var timeout: TimeInterval = 8.0
    public var processScope: ProcessScope = .ideAndCLI

    private static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelConfigPath =
        "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    private static let quotaSummaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let unleashPath = "/exa.language_server_pb.LanguageServerService/GetUnleashData"
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public init(timeout: TimeInterval = 8.0, processScope: ProcessScope = .ideAndCLI) {
        self.timeout = timeout
        self.processScope = processScope
    }

    public func fetch(matchingAccountEmail expectedAccountEmail: String? = nil) async throws
        -> AntigravityStatusSnapshot
    {
        let deadline = Date().addingTimeInterval(self.timeout)
        let processInfos = try await Self.detectProcessInfos(timeout: self.timeout, scope: self.processScope)
        let result = try await Self.fetchProcessSnapshots(processInfos: processInfos) { processInfo in
            try await Self.fetch(
                processInfo: processInfo,
                timeout: self.timeout,
                deadline: deadline)
        }

        if let bestSnapshot = Self.preferredLocalSnapshot(
            result.snapshots,
            matchingAccountEmail: expectedAccountEmail)
        {
            return bestSnapshot
        }
        throw result.lastError ?? AntigravityStatusProbeError.notRunning
    }

    public func fetchPlanInfoSummary() async throws -> AntigravityPlanInfoSummary? {
        let processInfo = try await Self.detectProcessInfo(timeout: self.timeout)
        let ports = try await Self.listeningPorts(pid: processInfo.pid, timeout: self.timeout)
        let endpoint = try await Self.resolveWorkingEndpoint(
            candidateEndpoints: Self.connectionCandidates(
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: self.timeout)
        return try await Self.makeParsedRequest(
            payload: RequestPayload(
                path: Self.getUserStatusPath,
                body: Self.defaultRequestBody()),
            context: RequestContext(
                endpoints: Self.requestEndpoints(
                    resolvedEndpoint: endpoint,
                    listeningPorts: ports,
                    languageServerCSRFToken: processInfo.csrfToken,
                    extensionServerPort: processInfo.extensionPort,
                    extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
                timeout: self.timeout),
            parse: Self.parsePlanInfoSummary)
    }

    static func localSnapshotScore(_ snapshot: AntigravityStatusSnapshot) -> Int {
        var score = 0
        if let quotaSummary = snapshot.quotaSummary {
            let buckets = quotaSummary.groups.flatMap(\.buckets)
            let knownBuckets = buckets.count(where: { !$0.disabled && $0.remainingFraction != nil })
            score += 1000
            score += quotaSummary.groups.count * 10
            score += buckets.count
            score += knownBuckets * 20
        } else {
            let knownRows = snapshot.modelQuotas.count(where: { $0.remainingFraction != nil })
            score += snapshot.modelQuotas.count
            score += knownRows * 10
        }
        if snapshot.accountEmail != nil {
            score += 2
        }
        if snapshot.accountPlan != nil {
            score += 1
        }
        return score
    }

    public static func isRunning(timeout: TimeInterval = 4.0) async -> Bool {
        await (try? self.detectProcessInfo(timeout: timeout)) != nil
    }

    public static func detectVersion(timeout: TimeInterval = 4.0) async -> String? {
        let running = await Self.isRunning(timeout: timeout)
        return running ? "running" : nil
    }

    // MARK: - CLI Local Fetch

    /// Fetch usage data from a known set of local ports (discovered via
    /// ``AntigravityCLISession``'s ``pid``), without requiring a running
    /// ``language_server`` process or CSRF token.
    ///
    /// The ``agy`` CLI exposes the same ``GetUserStatus`` gRPC-web endpoint as
    /// the desktop ``language_server``. Unlike the desktop endpoint, it does
    /// not require a CSRF token header.
    public func fetchFromPorts(_ ports: [Int], deadline: Date? = nil) async throws -> AntigravityStatusSnapshot {
        guard !ports.isEmpty else {
            throw AntigravityStatusProbeError.portDetectionFailed("no listening ports found")
        }
        let endpoints = Self.cliEndpoints(ports: ports)
        let context = RequestContext(endpoints: endpoints, timeout: self.timeout, deadline: deadline)
        return try await Self.fetchSnapshot(context: context)
    }

    // MARK: - Parsing

    public static func parseUserStatusResponse(_ data: Data) throws -> AntigravityStatusSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(UserStatusResponse.self, from: data)
        if let invalid = Self.invalidCode(response.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        guard let userStatus = response.userStatus else {
            throw AntigravityStatusProbeError.parseFailed("Missing userStatus")
        }

        let modelConfigs = userStatus.cascadeModelConfigData?.clientModelConfigs ?? []
        let models = modelConfigs.compactMap(Self.quotaFromConfig(_:))
        let email = userStatus.email
        // Prefer userTier.name (actual subscription tier) over planInfo (shows "Pro" for Ultra users)
        let planName = userStatus.userTier?.preferredName ?? userStatus.planStatus?.planInfo?.preferredName

        return AntigravityStatusSnapshot(
            modelQuotas: models,
            accountEmail: email,
            accountPlan: planName,
            source: .local)
    }

    static func parsePlanInfoSummary(_ data: Data) throws -> AntigravityPlanInfoSummary? {
        let decoder = JSONDecoder()
        let response = try decoder.decode(UserStatusResponse.self, from: data)
        if let invalid = Self.invalidCode(response.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        guard let userStatus = response.userStatus else {
            throw AntigravityStatusProbeError.parseFailed("Missing userStatus")
        }
        guard let planInfo = userStatus.planStatus?.planInfo else { return nil }
        return AntigravityPlanInfoSummary(
            planName: planInfo.planName,
            planDisplayName: planInfo.planDisplayName,
            displayName: planInfo.displayName,
            productName: planInfo.productName,
            planShortName: planInfo.planShortName)
    }

    static func parseCommandModelResponse(_ data: Data) throws -> AntigravityStatusSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(CommandModelConfigResponse.self, from: data)
        if let invalid = Self.invalidCode(response.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        let modelConfigs = response.clientModelConfigs ?? []
        let models = modelConfigs.compactMap(Self.quotaFromConfig(_:))
        return AntigravityStatusSnapshot(modelQuotas: models, accountEmail: nil, accountPlan: nil, source: .local)
    }

    private static func quotaFromConfig(_ config: ModelConfig) -> AntigravityModelQuota? {
        guard let quota = config.quotaInfo else { return nil }
        let reset = quota.resetTime.flatMap { Self.parseDate($0) }
        return AntigravityModelQuota(
            label: config.label,
            modelId: config.modelOrAlias.model,
            remainingFraction: quota.remainingFraction,
            resetTime: reset,
            resetDescription: nil)
    }

    static func invalidCode(_ code: CodeValue?) -> String? {
        guard let code else { return nil }
        if code.isOK { return nil }
        return "\(code.rawValue)"
    }

    static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    // MARK: - Port detection

    struct ProcessInfoResult {
        let pid: Int
        let extensionPort: Int?
        let extensionServerCSRFToken: String?
        let csrfToken: String
        let commandLine: String
    }

    struct AntigravityConnectionEndpoint: Equatable {
        enum Source: String {
            case languageServer = "language-server"
            case extensionServer = "extension-server"
            case cliHTTPS = "cli-https"
        }

        let scheme: String
        let port: Int
        let csrfToken: String
        let source: Source
        /// Whether this endpoint needs a CSRF token header.
        /// The CLI HTTPS endpoint (``Source/cliHTTPS``) speaks the same HTTP API
        /// but does not require a CSRF token.
        var requiresCSRFToken: Bool {
            switch self.source {
            case .languageServer, .extensionServer: true
            case .cliHTTPS: false
            }
        }

        func matchesRequestTarget(_ other: Self) -> Bool {
            self.scheme == other.scheme && self.port == other.port && self.csrfToken == other.csrfToken
        }
    }

    private static func detectProcessInfo(
        timeout: TimeInterval,
        scope: ProcessScope = .ideAndCLI) async throws -> ProcessInfoResult
    {
        let processInfos = try await self.detectProcessInfos(timeout: timeout, scope: scope)
        guard let first = processInfos.first else {
            throw AntigravityStatusProbeError.notRunning
        }
        return first
    }

    private static func detectProcessInfos(
        timeout: TimeInterval,
        scope: ProcessScope = .ideAndCLI) async throws -> [ProcessInfoResult]
    {
        let env = ProcessInfo.processInfo.environment
        let result = try await SubprocessRunner.run(
            binary: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            environment: env,
            timeout: timeout,
            label: "antigravity-ps")

        return try Self.processInfos(fromProcessListOutput: result.stdout, scope: scope)
    }

    static func processInfo(
        fromProcessListOutput output: String,
        scope: ProcessScope = .ideAndCLI) throws -> ProcessInfoResult
    {
        let processInfos = try self.processInfos(fromProcessListOutput: output, scope: scope)
        guard let first = processInfos.first else {
            throw AntigravityStatusProbeError.notRunning
        }
        return first
    }

    static func processInfos(
        fromProcessListOutput output: String,
        scope: ProcessScope = .ideAndCLI) throws -> [ProcessInfoResult]
    {
        let lines = output.split(separator: "\n")
        var sawTokenlessIDE = false
        var results: [ProcessInfoResult] = []
        for line in lines {
            let text = String(line)
            guard let match = Self.matchProcessLine(text) else { continue }
            guard let kind = Self.antigravityProcessKind(match.command) else { continue }
            if !Self.processKind(kind, matches: scope) { continue }
            // The IDE language server authenticates local requests with a
            // `--csrf_token` and must keep requiring it: skip a tokenless IDE
            // or app match so a later valid server can still be found (and surface
            // `missingCSRFToken` if none is). The CLI's language server exposes
            // no token flag and needs none, so an empty token is allowed there.
            guard let token = Self.resolvedCSRFToken(forKind: kind, command: match.command) else {
                sawTokenlessIDE = true
                continue
            }
            let port = Self.extractPort("--extension_server_port", from: match.command)
            let extensionServerCSRFToken = Self.extractFlag("--extension_server_csrf_token", from: match.command)
            results.append(ProcessInfoResult(
                pid: match.pid,
                extensionPort: port,
                extensionServerCSRFToken: extensionServerCSRFToken,
                csrfToken: token,
                commandLine: match.command))
        }

        if !results.isEmpty {
            return results
        }
        if sawTokenlessIDE {
            throw AntigravityStatusProbeError.missingCSRFToken
        }
        throw AntigravityStatusProbeError.notRunning
    }

    private struct ProcessLineMatch {
        let pid: Int
        let command: String
    }

    private static func matchProcessLine(_ line: String) -> ProcessLineMatch? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
        return ProcessLineMatch(pid: pid, command: String(parts[1]))
    }

    enum AntigravityProcessKind: Equatable {
        /// Antigravity 2.0 app language server. Requires a `--csrf_token`.
        case app
        /// Antigravity IDE extension language server. Requires a `--csrf_token`.
        case ide
        /// CLI language server (`agy` / `antigravity-cli`). Needs no CSRF token.
        case cli
    }

    static func isAntigravityLanguageServerCommandLine(_ command: String) -> Bool {
        self.antigravityProcessKind(command) != nil
    }

    /// Classify a process command line as the Antigravity app language server,
    /// the Antigravity IDE language server, the Antigravity CLI language server,
    /// or neither. Desktop language servers take precedence so their CSRF-token
    /// requirement is preserved.
    static func antigravityProcessKind(_ command: String) -> AntigravityProcessKind? {
        let lower = command.lowercased()
        if Self.isLanguageServerCommandLine(lower), Self.isAntigravityCommandLine(lower) {
            return Self.isAntigravityIDECommandLine(lower) ? .ide : .app
        }
        if Self.isAntigravityCLICommandLine(lower) {
            return .cli
        }
        return nil
    }

    private static func processKind(_ kind: AntigravityProcessKind, matches scope: ProcessScope) -> Bool {
        switch scope {
        case .ideAndCLI:
            true
        case .appOnly:
            kind == .app
        case .ideOnly:
            kind == .ide
        }
    }

    /// Resolve the CSRF token to use for a matched process, or `nil` when the
    /// match must be skipped. IDE matches keep requiring `--csrf_token`
    /// (tokenless IDE matches are skipped). CLI matches accept an empty token
    /// because the CLI's language server requires none.
    static func resolvedCSRFToken(forKind kind: AntigravityProcessKind, command: String) -> String? {
        if let token = extractFlag("--csrf_token", from: command) {
            return token
        }
        switch kind {
        case .app, .ide: return nil
        case .cli: return ""
        }
    }

    private static func isLanguageServerCommandLine(_ lowerCommand: String) -> Bool {
        let pattern = #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#
        return lowerCommand.range(of: pattern, options: .regularExpression) != nil
    }

    /// The Antigravity CLI (`agy` / `antigravity-cli`) hosts the same language
    /// server locally as the IDE, but launches it without a `--csrf_token` flag
    /// and under a different process name. Match it so usage can be probed when
    /// only the CLI is running.
    private static func isAntigravityCLICommandLine(_ lowerCommand: String) -> Bool {
        let cliPathPattern = #"(^|[/\\])(antigravity-cli|antigravity_cli)([\s/\\]|$)"#
        if lowerCommand.range(of: cliPathPattern, options: .regularExpression) != nil {
            return true
        }
        let agyPattern = #"(^|[/\\])agy(\s|$)"#
        return lowerCommand.range(of: agyPattern, options: .regularExpression) != nil
    }

    private static func isAntigravityCommandLine(_ command: String) -> Bool {
        if command.contains("--app_data_dir") && command.contains("antigravity") { return true }
        if command.contains("antigravity.app/") || command.contains("antigravity.app\\") { return true }
        if command.contains("antigravity ide.app/") || command.contains("antigravity ide.app\\") { return true }
        if command.contains("/antigravity/") || command.contains("\\antigravity\\") { return true }
        return false
    }

    private static func isAntigravityIDECommandLine(_ lowerCommand: String) -> Bool {
        [
            "antigravity ide.app/",
            "antigravity ide.app\\",
            "--app_data_dir antigravity-ide",
            "--app_data_dir=antigravity-ide",
            "/extensions/antigravity/bin/language_server",
            "\\extensions\\antigravity\\bin\\language_server",
        ].contains { lowerCommand.contains($0) }
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[tokenRange])
    }

    private static func extractPort(_ flag: String, from command: String) -> Int? {
        guard let raw = extractFlag(flag, from: command) else { return nil }
        return Int(raw)
    }

    static func listeningPorts(pid: Int, timeout: TimeInterval) async throws -> [Int] {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })

        guard let lsof else {
            throw AntigravityStatusProbeError.portDetectionFailed("lsof not available")
        }

        let env = ProcessInfo.processInfo.environment
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                binary: lsof,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
                environment: env,
                timeout: timeout,
                label: "antigravity-lsof")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr)
            where code == 1 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AntigravityStatusProbeError.portDetectionFailed("no listening ports found")
        }
        let ports = Self.parseListeningPorts(result.stdout)
        if ports.isEmpty {
            throw AntigravityStatusProbeError.portDetectionFailed("no listening ports found")
        }
        return ports
    }

    private static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match,
                  let range = Range(match.range(at: 1), in: output),
                  let value = Int(output[range]) else { return }
            ports.insert(value)
        }
        return ports.sorted()
    }

    static func connectionCandidates(
        listeningPorts: [Int],
        languageServerCSRFToken: String,
        extensionServerPort: Int?,
        extensionServerCSRFToken: String?) -> [AntigravityConnectionEndpoint]
    {
        var endpoints = Self.languageServerEndpoints(
            listeningPorts: listeningPorts,
            languageServerCSRFToken: languageServerCSRFToken)

        for endpoint in Self.extensionServerEndpoints(
            extensionServerPort: extensionServerPort,
            languageServerCSRFToken: languageServerCSRFToken,
            extensionServerCSRFToken: extensionServerCSRFToken)
        {
            guard !endpoints.contains(where: { $0.matchesRequestTarget(endpoint) }) else { continue }
            endpoints.append(endpoint)
        }

        return endpoints
    }

    static func requestEndpoints(
        resolvedEndpoint: AntigravityConnectionEndpoint,
        listeningPorts: [Int],
        languageServerCSRFToken: String,
        extensionServerPort: Int?,
        extensionServerCSRFToken: String?) -> [AntigravityConnectionEndpoint]
    {
        var endpoints = [resolvedEndpoint]

        if resolvedEndpoint.source == .extensionServer {
            Self.appendUniqueRequestTargets(
                from: Self.extensionServerEndpoints(
                    extensionServerPort: extensionServerPort,
                    languageServerCSRFToken: languageServerCSRFToken,
                    extensionServerCSRFToken: extensionServerCSRFToken),
                to: &endpoints)
            Self.appendUniqueRequestTargets(
                from: Self.languageServerEndpoints(
                    listeningPorts: listeningPorts,
                    languageServerCSRFToken: languageServerCSRFToken),
                to: &endpoints)
        } else {
            Self.appendUniqueRequestTargets(
                from: Self.languageServerEndpoints(
                    listeningPorts: listeningPorts,
                    languageServerCSRFToken: languageServerCSRFToken),
                to: &endpoints)
            Self.appendUniqueRequestTargets(
                from: Self.extensionServerEndpoints(
                    extensionServerPort: extensionServerPort,
                    languageServerCSRFToken: languageServerCSRFToken,
                    extensionServerCSRFToken: extensionServerCSRFToken),
                to: &endpoints)
        }

        return endpoints
    }

    private static func languageServerEndpoints(
        listeningPorts: [Int],
        languageServerCSRFToken: String) -> [AntigravityConnectionEndpoint]
    {
        listeningPorts.flatMap { port in
            self.localProbeSchemes.map { scheme in
                AntigravityConnectionEndpoint(
                    scheme: scheme,
                    port: port,
                    csrfToken: languageServerCSRFToken,
                    source: .languageServer)
            }
        }
    }

    private static func extensionServerEndpoints(
        extensionServerPort: Int?,
        languageServerCSRFToken: String,
        extensionServerCSRFToken: String?) -> [AntigravityConnectionEndpoint]
    {
        guard let extensionServerPort else { return [] }

        var endpoints: [AntigravityConnectionEndpoint] = []
        if let extensionServerCSRFToken {
            endpoints.append(
                AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: extensionServerPort,
                    csrfToken: extensionServerCSRFToken,
                    source: .extensionServer))
        }

        if extensionServerCSRFToken != languageServerCSRFToken {
            endpoints.append(
                AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: extensionServerPort,
                    csrfToken: languageServerCSRFToken,
                    source: .extensionServer))
        }

        return endpoints
    }

    private static func appendUniqueRequestTargets(
        from candidates: [AntigravityConnectionEndpoint],
        to endpoints: inout [AntigravityConnectionEndpoint])
    {
        for endpoint in candidates {
            guard !endpoints.contains(where: { $0.matchesRequestTarget(endpoint) }) else { continue }
            endpoints.append(endpoint)
        }
    }

    static func resolveWorkingEndpoint(
        candidateEndpoints: [AntigravityConnectionEndpoint],
        timeout: TimeInterval,
        deadline: Date? = nil,
        testConnectivity: @escaping @Sendable (AntigravityConnectionEndpoint, TimeInterval) async -> Bool = Self
            .testEndpointConnectivity) async throws -> AntigravityConnectionEndpoint
    {
        for (index, endpoint) in candidateEndpoints.enumerated() {
            let remainingAttemptCount = candidateEndpoints.count - index
            guard let attemptTimeout = timeoutForEndpointAttempt(
                timeout: timeout,
                deadline: deadline,
                remainingAttemptCount: remainingAttemptCount)
            else {
                throw AntigravityStatusProbeError.timedOut
            }
            let ok = await testConnectivity(endpoint, attemptTimeout)
            if ok { return endpoint }
        }
        if let fallback = fallbackProbeEndpoint(candidateEndpoints) {
            self.log.debug("Port probe fell back to best-effort endpoint", metadata: [
                "source": fallback.source.rawValue,
                "scheme": fallback.scheme,
                "port": "\(fallback.port)",
            ])
            return fallback
        }
        throw AntigravityStatusProbeError.portDetectionFailed("no working API port found")
    }

    private static func timeoutForEndpointAttempt(
        timeout: TimeInterval,
        deadline: Date?,
        remainingAttemptCount: Int) -> TimeInterval?
    {
        guard let deadline else { return timeout }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return min(timeout, remaining / Double(max(1, remainingAttemptCount)))
    }

    static func fallbackProbePort(ports: [Int], extensionPort: Int?) -> Int? {
        if let nonExtension = ports.first(where: { $0 != extensionPort }) {
            return nonExtension
        }
        if let extensionPort {
            return extensionPort
        }
        return ports.first
    }

    static func isReachableProbeError(_ error: Error) -> Bool {
        guard case let AntigravityStatusProbeError.apiError(message) = error else { return false }
        return message.hasPrefix("HTTP ")
    }

    private static func fallbackProbeEndpoint(
        _ endpoints: [AntigravityConnectionEndpoint]) -> AntigravityConnectionEndpoint?
    {
        if let languageServerEndpoint = endpoints.first(where: { $0.source == .languageServer }) {
            return languageServerEndpoint
        }
        return endpoints.first
    }

    private static func testEndpointConnectivity(
        _ endpoint: AntigravityConnectionEndpoint,
        timeout: TimeInterval) async -> Bool
    {
        do {
            _ = try await self.makeRequest(
                payload: RequestPayload(
                    path: self.unleashPath,
                    body: self.unleashRequestBody()),
                context: RequestContext(endpoints: [endpoint], timeout: timeout))
            return true
        } catch {
            if self.isReachableProbeError(error) {
                self.log.debug("Port probe received HTTP response; treating endpoint as reachable", metadata: [
                    "source": endpoint.source.rawValue,
                    "scheme": endpoint.scheme,
                    "port": "\(endpoint.port)",
                    "error": error.localizedDescription,
                ])
                return true
            }
            self.log.debug("Port probe failed", metadata: [
                "source": endpoint.source.rawValue,
                "scheme": endpoint.scheme,
                "port": "\(endpoint.port)",
                "error": error.localizedDescription,
            ])
            return false
        }
    }

    // MARK: - HTTP

    struct RequestPayload {
        let path: String
        let body: [String: Any]
    }

    struct RequestContext {
        let endpoints: [AntigravityConnectionEndpoint]
        let timeout: TimeInterval
        let deadline: Date?

        init(endpoints: [AntigravityConnectionEndpoint], timeout: TimeInterval, deadline: Date? = nil) {
            self.endpoints = endpoints
            self.timeout = timeout
            self.deadline = deadline
        }

        func timeoutForNextAttempt() -> TimeInterval? {
            AntigravityStatusProbe.timeoutForNextAttempt(timeout: self.timeout, deadline: self.deadline)
        }
    }

    private static func defaultRequestBody() -> [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ],
        ]
    }

    private static func unleashRequestBody() -> [String: Any] {
        [
            "context": [
                "properties": [
                    "devMode": "false",
                    "extensionVersion": "unknown",
                    "hasAnthropicModelAccess": "true",
                    "ide": "antigravity",
                    "ideVersion": "unknown",
                    "installationId": "codexbar",
                    "language": "UNSPECIFIED",
                    "os": "macos",
                    "requestedModelId": "MODEL_UNSPECIFIED",
                ],
            ],
        ]
    }

    static func fetchSnapshot(
        context: RequestContext,
        send: @escaping @Sendable (RequestPayload, AntigravityConnectionEndpoint, TimeInterval) async throws -> Data =
            sendRequest) async throws -> AntigravityStatusSnapshot
    {
        do {
            let quotaSummary = try await self.makeParsedRequest(
                payload: RequestPayload(
                    path: self.quotaSummaryPath,
                    body: ["forceRefresh": true]),
                context: self.quotaSummaryRequestContext(from: context),
                send: send,
                parse: self.parseQuotaSummaryResponse)
            guard quotaSummary.quotaSummary?.groups.contains(where: { group in
                group.buckets.contains { !$0.disabled && $0.remainingFraction != nil }
            }) == true else {
                throw AntigravityStatusProbeError.parseFailed("Quota summary has no usable quota buckets")
            }
            let identity = try? await self.makeParsedRequest(
                payload: RequestPayload(
                    path: self.getUserStatusPath,
                    body: self.defaultRequestBody()),
                context: self.identityRequestContext(from: context),
                send: send,
                parse: self.parseUserStatusResponse)
            return quotaSummary.withIdentity(from: identity)
        } catch {
            self.log.debug("Antigravity quota summary unavailable; falling back to model quotas", metadata: [
                "error": error.localizedDescription,
            ])
        }

        do {
            return try await self.makeParsedRequest(
                payload: RequestPayload(
                    path: self.getUserStatusPath,
                    body: self.defaultRequestBody()),
                context: self.legacyUserStatusRequestContext(from: context),
                send: send,
                parse: self.parseUserStatusResponse)
        } catch {
            return try await self.makeParsedRequest(
                payload: RequestPayload(
                    path: self.commandModelConfigPath,
                    body: self.defaultRequestBody()),
                context: context,
                send: send,
                parse: self.parseCommandModelResponse)
        }
    }

    private static func legacyUserStatusRequestContext(from context: RequestContext) -> RequestContext {
        guard let deadline = context.deadline else { return context }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let userStatusBudget = remaining / 2
        return RequestContext(
            endpoints: context.endpoints,
            timeout: min(context.timeout, userStatusBudget),
            deadline: Date().addingTimeInterval(userStatusBudget))
    }

    private static func quotaSummaryRequestContext(from context: RequestContext) -> RequestContext {
        guard let deadline = context.deadline else { return context }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let quotaSummaryBudget = remaining / 2
        return RequestContext(
            endpoints: context.endpoints,
            timeout: min(context.timeout, quotaSummaryBudget),
            deadline: Date().addingTimeInterval(quotaSummaryBudget))
    }

    private static func identityRequestContext(from context: RequestContext) -> RequestContext {
        RequestContext(
            endpoints: context.endpoints,
            timeout: min(context.timeout, 1),
            deadline: context.deadline)
    }

    private static func makeRequest(
        payload: RequestPayload,
        context: RequestContext) async throws -> Data
    {
        try await self.sendRequest(payload: payload, context: context)
    }

    static func makeParsedRequest<T>(
        payload: RequestPayload,
        context: RequestContext,
        send: @escaping @Sendable (RequestPayload, AntigravityConnectionEndpoint, TimeInterval) async throws -> Data =
            sendRequest,
        parse: @escaping @Sendable (Data) throws -> T) async throws -> T
    {
        var lastError: Error?

        for endpoint in context.endpoints {
            guard let timeout = context.timeoutForNextAttempt() else {
                lastError = lastError ?? AntigravityStatusProbeError.timedOut
                break
            }
            do {
                let data = try await send(payload, endpoint, timeout)
                return try parse(data)
            } catch {
                lastError = error
                Self.log.debug("Antigravity request/parse attempt failed", metadata: [
                    "path": payload.path,
                    "source": endpoint.source.rawValue,
                    "scheme": endpoint.scheme,
                    "port": "\(endpoint.port)",
                    "error": error.localizedDescription,
                ])
            }
        }

        throw lastError ?? AntigravityStatusProbeError.apiError("Invalid response")
    }

    private static func sendRequest(
        payload: RequestPayload,
        context: RequestContext) async throws -> Data
    {
        var lastError: Error?

        for endpoint in context.endpoints {
            guard let timeout = context.timeoutForNextAttempt() else {
                lastError = lastError ?? AntigravityStatusProbeError.timedOut
                break
            }
            do {
                return try await Self.sendRequest(payload: payload, endpoint: endpoint, timeout: timeout)
            } catch {
                lastError = error
                Self.log.debug("Antigravity request attempt failed", metadata: [
                    "path": payload.path,
                    "source": endpoint.source.rawValue,
                    "scheme": endpoint.scheme,
                    "port": "\(endpoint.port)",
                    "error": error.localizedDescription,
                ])
            }
        }

        throw lastError ?? AntigravityStatusProbeError.apiError("Invalid URL")
    }

    private static func sendRequest(
        payload: RequestPayload,
        endpoint: AntigravityConnectionEndpoint,
        timeout: TimeInterval) async throws -> Data
    {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(payload.path)") else {
            throw AntigravityStatusProbeError.apiError("Invalid URL")
        }

        let body = try JSONSerialization.data(withJSONObject: payload.body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if endpoint.requiresCSRFToken {
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        #if !os(Linux)
        config.waitsForConnectivity = false
        #endif

        let delegate = LocalhostSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await delegate.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityStatusProbeError.apiError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityStatusProbeError.apiError("HTTP \(http.statusCode): \(message)")
        }
        return data
    }
}
