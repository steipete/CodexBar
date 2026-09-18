import Foundation

public enum OpenCodexUsageStatus: String, Sendable, Equatable, Codable {
    case reported
    case estimated
    case unreported
    case unsupported
}

public struct OpenCodexTokenUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var reasoningOutputTokens: Int?
    public var totalTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        totalTokens: Int? = nil)
    {
        self.inputTokens = Self.nonnegative(inputTokens)
        self.outputTokens = Self.nonnegative(outputTokens)
        self.cachedInputTokens = Self.nonnegative(cachedInputTokens)
        self.cacheReadInputTokens = Self.nonnegative(cacheReadInputTokens)
        self.cacheCreationInputTokens = Self.nonnegative(cacheCreationInputTokens)
        self.reasoningOutputTokens = Self.nonnegative(reasoningOutputTokens)
        self.totalTokens = Self.nonnegative(totalTokens)
    }

    public var cacheReadTokens: Int? {
        self.cacheReadInputTokens ?? self.cachedInputTokens
    }

    public var resolvedTotalTokens: Int? {
        self.resolvedTotalCount.value
    }

    var tokenMix: CostUsageTokenMix {
        CostUsageTokenMix(
            inputTokens: self.inputTokens,
            outputTokens: self.outputTokens,
            cacheReadTokens: self.cacheReadTokens,
            cacheCreationTokens: self.cacheCreationInputTokens,
            reasoningTokens: self.reasoningOutputTokens)
    }

    var resolvedTotalCount: CostUsageDailyReport.OptionalCountAccumulator {
        if let totalTokens { return .init(totalTokens) }
        var count = CostUsageDailyReport.OptionalCountAccumulator()
        for value in [self.inputTokens, self.outputTokens, self.cacheReadTokens, self.cacheCreationInputTokens] {
            count.add(value)
        }
        return count
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

public struct OpenCodexUsageEntry: Sendable, Equatable {
    public let requestID: String
    public let timestamp: Date
    public let provider: String
    public let model: String
    public let usageStatus: OpenCodexUsageStatus
    public let accountLogLabel: String?
    public let surface: String?
    public let conversationID: String?
    public let usage: OpenCodexTokenUsage?
    public let totalTokens: Int?

    public init(
        requestID: String,
        timestamp: Date,
        provider: String,
        model: String,
        usageStatus: OpenCodexUsageStatus,
        accountLogLabel: String? = nil,
        surface: String? = nil,
        conversationID: String? = nil,
        usage: OpenCodexTokenUsage? = nil,
        totalTokens: Int? = nil)
    {
        self.requestID = requestID
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.usageStatus = usageStatus
        self.accountLogLabel = Self.normalizedAccountLogLabel(accountLogLabel)
        self.surface = surface
        self.conversationID = conversationID
        self.usage = usage
        self.totalTokens = totalTokens
    }

    public var resolvedTotalTokens: Int? {
        self.resolvedTotalCount.value
    }

    var resolvedTotalCount: CostUsageDailyReport.OptionalCountAccumulator {
        if let totalTokens { return .init(totalTokens) }
        return self.usage?.resolvedTotalCount ?? .init()
    }

    public var displayAccountLabel: String {
        self.accountLogLabel ?? "main"
    }

    static func normalizedAccountLogLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "main" {
            return "main"
        }
        guard trimmed.count >= 2, trimmed.first == "p" else { return nil }
        let digits = trimmed.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }
}

public enum OpenCodexUsageLog {
    public static let sourceID = "opencodex"
    public static let displayName = "OpenCodex"

    public static func usageLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL?
    {
        if let override = environment["OPENCODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("usage.jsonl", isDirectory: false)
        }
        if TestProcessSafety.isRunning || TestProcessSafety.isRunningUnderTests(environment: environment) {
            return nil
        }
        return homeDirectory
            .appendingPathComponent(".opencodex", isDirectory: true)
            .appendingPathComponent("usage.jsonl", isDirectory: false)
    }

    public static func cacheRoot(
        fileManager: FileManager = .default,
        codexBarCachesDirectory: URL? = nil) -> URL
    {
        let codexBarRoot = codexBarCachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexBar", isDirectory: true)
            ?? AppGroupSupport.localFallbackDirectory(fileManager: fileManager)
        return codexBarRoot.appendingPathComponent("opencodex-usage", isDirectory: true)
    }
}
