import Foundation

public enum MiniMaxDiagnosticExportErrorCategory: String, Sendable, Codable {
    case auth
    case network
    case parse
    case timeout
    case unknown
}

public struct MiniMaxFetchAttemptSummary: Sendable, Codable {
    public let strategyID: String
    public let wasAvailable: Bool
    public let errorCode: String?
    public let errorCategory: MiniMaxDiagnosticExportErrorCategory

    public init(
        strategyID: String,
        wasAvailable: Bool,
        errorCode: String?,
        errorCategory: MiniMaxDiagnosticExportErrorCategory)
    {
        self.strategyID = strategyID
        self.wasAvailable = wasAvailable
        self.errorCode = errorCode
        self.errorCategory = errorCategory
    }
}

public struct MiniMaxDiagnosticExport: Sendable, Codable {
    public let schemaVersion: String
    public let provider: UsageProvider
    public let authMode: String
    public let region: String?
    public let sourceLabel: String?
    public let strategyID: String?
    public let fieldsPresent: Set<String>
    public let servicesCount: Int
    public let billingSummaryPresent: Bool
    public let fetchAttemptsSummary: [MiniMaxFetchAttemptSummary]
    public let redactionPolicyVersion: String
    public let exportedAt: Date

    public init(
        schemaVersion: String = "1.0",
        provider: UsageProvider = .minimax,
        authMode: String,
        region: String?,
        sourceLabel: String?,
        strategyID: String?,
        fieldsPresent: Set<String>,
        servicesCount: Int,
        billingSummaryPresent: Bool,
        fetchAttemptsSummary: [MiniMaxFetchAttemptSummary],
        redactionPolicyVersion: String = "1.0",
        exportedAt: Date)
    {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.authMode = authMode
        self.region = region
        self.sourceLabel = sourceLabel
        self.strategyID = strategyID
        self.fieldsPresent = fieldsPresent
        self.servicesCount = servicesCount
        self.billingSummaryPresent = billingSummaryPresent
        self.fetchAttemptsSummary = fetchAttemptsSummary
        self.redactionPolicyVersion = redactionPolicyVersion
        self.exportedAt = exportedAt
    }
}

public enum MiniMaxDiagnosticExportBuilder {
    private static let allowlistedFields: Set<String> = [
        "planName",
        "availablePrompts",
        "currentPrompts",
        "remainingPrompts",
        "windowMinutes",
        "usedPercent",
        "resetsAt",
        "services",
        "billingSummary",
    ]

    private static let authErrorCodes: Set<String> = ["401", "403"]
    private static let boundedHTTPStatusCodeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<!\d)([1-5][0-9]{2})(?!\d)"#)

    public static func build(
        from outcome: ProviderFetchOutcome,
        region: MiniMaxAPIRegion?,
        authMode: String,
        snapshot: MiniMaxUsageSnapshot?,
        now: Date = Date()) -> MiniMaxDiagnosticExport
    {
        let fieldsPresent = Self.allowlistedFields.filter { key in
            Self.snapshotHasField(key, snapshot: snapshot)
        }

        let servicesCount = snapshot?.services?.count ?? 0
        let billingSummaryPresent = snapshot?.billingSummary != nil

        var fetchAttemptsSummary: [MiniMaxFetchAttemptSummary] = []
        for attempt in outcome.attempts {
            let summary = Self.makeAttemptSummary(attempt)
            fetchAttemptsSummary.append(summary)
        }

        let resultValue = outcome.result
        var sourceLabel: String?
        var strategyID: String?
        if case let .success(result) = resultValue {
            sourceLabel = result.sourceLabel
            strategyID = result.strategyID
        }

        return MiniMaxDiagnosticExport(
            authMode: authMode,
            region: region?.rawValue,
            sourceLabel: sourceLabel,
            strategyID: strategyID,
            fieldsPresent: Set(fieldsPresent),
            servicesCount: servicesCount,
            billingSummaryPresent: billingSummaryPresent,
            fetchAttemptsSummary: fetchAttemptsSummary,
            exportedAt: now)
    }

    private static func snapshotHasField(_ key: String, snapshot: MiniMaxUsageSnapshot?) -> Bool {
        guard let snapshot else { return false }
        switch key {
        case "planName":
            return snapshot.planName != nil
        case "availablePrompts":
            return snapshot.availablePrompts != nil
        case "currentPrompts":
            return snapshot.currentPrompts != nil
        case "remainingPrompts":
            return snapshot.remainingPrompts != nil
        case "windowMinutes":
            return snapshot.windowMinutes != nil
        case "usedPercent":
            return snapshot.usedPercent != nil
        case "resetsAt":
            return snapshot.resetsAt != nil
        case "services":
            return snapshot.services != nil && !(snapshot.services?.isEmpty ?? true)
        case "billingSummary":
            return snapshot.billingSummary != nil
        default:
            return false
        }
    }

    private static func makeAttemptSummary(
        _ attempt: ProviderFetchAttempt) -> MiniMaxFetchAttemptSummary
    {
        var errorCode: String?
        var errorCategory: MiniMaxDiagnosticExportErrorCategory = .unknown

        if let rawError = attempt.errorDescription, !rawError.isEmpty {
            let redactedError = LogRedactor.redact(rawError)
            errorCode = Self.extractErrorCode(from: redactedError)
            errorCategory = Self.categorizeError(errorCode: errorCode, redactedError: redactedError)
        }

        return MiniMaxFetchAttemptSummary(
            strategyID: attempt.strategyID,
            wasAvailable: attempt.wasAvailable,
            errorCode: errorCode,
            errorCategory: errorCategory)
    }

    private static func extractErrorCode(from redactedError: String) -> String? {
        if let statusCode = self.extractBoundedHTTPStatusCode(from: redactedError) {
            return statusCode
        }

        let lowercased = redactedError.lowercased()
        if lowercased.contains("timeout") {
            return "timeout"
        }
        if lowercased.contains("network") {
            return "network"
        }
        if lowercased.contains("parse") {
            return "parse"
        }
        return nil
    }

    private static func categorizeError(
        errorCode: String?,
        redactedError: String) -> MiniMaxDiagnosticExportErrorCategory
    {
        if let code = errorCode {
            if self.authErrorCodes.contains(code) {
                return .auth
            }
            if code.lowercased().contains("timeout") {
                return .timeout
            }
            if code.lowercased().contains("network") {
                return .network
            }
            if code.lowercased().contains("parse") {
                return .parse
            }
        }

        let lowercased = redactedError.lowercased()
        if self.containsBoundedHTTPStatusCode("401", in: lowercased)
            || self.containsBoundedHTTPStatusCode("403", in: lowercased)
            || lowercased.contains("unauthorized")
            || lowercased.contains("forbidden")
            || lowercased.contains("auth")
        {
            return .auth
        }
        if lowercased.contains("timeout") || lowercased.contains("timed out") {
            return .timeout
        }
        if lowercased.contains("network") || lowercased.contains("connection") {
            return .network
        }
        if lowercased.contains("parse") || lowercased.contains("decode") || lowercased.contains("invalid") {
            return .parse
        }

        return .unknown
    }

    private static func extractBoundedHTTPStatusCode(from text: String) -> String? {
        guard let regex = self.boundedHTTPStatusCodeRegex else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let codeRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[codeRange])
    }

    private static func containsBoundedHTTPStatusCode(_ code: String, in text: String) -> Bool {
        guard let regex = self.boundedHTTPStatusCodeRegex else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches {
            guard let codeRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            if text[codeRange] == code {
                return true
            }
        }
        return false
    }
}
