import Foundation

public enum OpenCodexUsageStatus: String, Sendable, Equatable, Codable {
    case reported
    case estimated
    case unreported
    case unsupported
}

public struct OpenCodexTokenUsage: Sendable, Equatable, Codable {
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
        if let totalTokens {
            return totalTokens
        }
        let parts = [
            self.inputTokens,
            self.outputTokens,
            self.cacheReadTokens,
            self.cacheCreationInputTokens,
        ].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +)
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

public enum OpenCodexUsageCredentialSource: String, Sendable, Equatable, Codable {
    case grokOAuth = "grok-oauth"
    case xaiAPIKey = "xai-api-key"
}

public struct OpenCodexUsageAttempt: Sendable, Equatable, Codable {
    public let ordinal: Int
    public let provider: String
    public let model: String
    public let credentialSource: OpenCodexUsageCredentialSource?
    public let usageStatus: OpenCodexUsageStatus
    public let sendCount: Int
    public let locallyAnswered: Bool
    public let usage: OpenCodexTokenUsage?
    public let totalTokens: Int?
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
    public let attempts: [OpenCodexUsageAttempt]
    /// Set only on a derived physical-attempt entry, never from top-level JSON metadata.
    let credentialSource: OpenCodexUsageCredentialSource?

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
        totalTokens: Int? = nil,
        attempts: [OpenCodexUsageAttempt] = [])
    {
        self.credentialSource = nil
        self.attempts = attempts
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

    init(parent: OpenCodexUsageEntry, attempt: OpenCodexUsageAttempt) {
        // A length prefix avoids collisions between request IDs containing separators.
        self.requestID = "ocx-attempt:\(parent.requestID.utf8.count):\(parent.requestID):\(attempt.ordinal)"
        self.timestamp = parent.timestamp
        self.provider = attempt.provider
        self.model = attempt.model
        self.usageStatus = attempt.usageStatus
        self.accountLogLabel = nil
        self.surface = parent.surface
        self.conversationID = parent.conversationID
        self.usage = attempt.usage
        self.totalTokens = attempt.totalTokens
        self.attempts = []
        self.credentialSource = attempt.credentialSource
    }

    public var resolvedTotalTokens: Int? {
        self.totalTokens ?? self.usage?.resolvedTotalTokens
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
        self.rootURL(environment: environment, homeDirectory: homeDirectory)?
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

    private static func rootURL(
        environment: [String: String],
        homeDirectory: URL) -> URL?
    {
        if let override = environment["OPENCODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if Self.isRunningTests(environment) || Self.isRunningTests(ProcessInfo.processInfo.environment) {
            return nil
        }
        return homeDirectory.appendingPathComponent(".opencodex", isDirectory: true)
    }

    private static func isRunningTests(_ environment: [String: String]) -> Bool {
        let keys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "SWIFT_TESTING_ENABLED",
            "TESTING_LIBRARY_VERSION",
            "SWIFT_TESTING",
        ]
        if keys.contains(where: { environment[$0] != nil }) {
            return true
        }
        if keys.contains(where: { ProcessInfo.processInfo.environment[$0] != nil }) {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        #if os(macOS)
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        #else
        // Bundle.allBundles crashes on Linux (swift-corelibs-foundation). SwiftPM
        // builds test executables with a `.xctest` suffix, so detect the test
        // process from the main executable instead of enumerating bundles.
        return Bundle.main.executableURL?.path.hasSuffix(".xctest") ?? false
        #endif
    }
}
