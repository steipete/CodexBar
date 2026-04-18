import Foundation

public struct ClaudeSourcePlanningInput: Equatable, Sendable {
    public let runtime: ProviderRuntime
    public let selectedDataSource: ClaudeUsageDataSource
    public let webExtrasEnabled: Bool
    public let hasWebSession: Bool
    public let hasCLI: Bool
    public let hasOAuthCredentials: Bool

    public init(
        runtime: ProviderRuntime,
        selectedDataSource: ClaudeUsageDataSource,
        webExtrasEnabled: Bool,
        hasWebSession: Bool,
        hasCLI: Bool,
        hasOAuthCredentials: Bool)
    {
        self.runtime = runtime
        self.selectedDataSource = selectedDataSource
        self.webExtrasEnabled = webExtrasEnabled
        self.hasWebSession = hasWebSession
        self.hasCLI = hasCLI
        self.hasOAuthCredentials = hasOAuthCredentials
    }
}

public enum ClaudeSourcePlanReason: String, Equatable, Sendable {
    case explicitSourceSelection = "explicit-source-selection"
    case appAutoPreferredOAuth = "app-auto-preferred-oauth"
    case appAutoFallbackCLI = "app-auto-fallback-cli"
    case appAutoFallbackWeb = "app-auto-fallback-web"
    case cliAutoPreferredWeb = "cli-auto-preferred-web"
    case cliAutoFallbackCLI = "cli-auto-fallback-cli"
}

public struct ClaudeFetchPlanStep: Equatable, Sendable {
    public let dataSource: ClaudeUsageDataSource
    public let inclusionReason: ClaudeSourcePlanReason
    public let isPlausiblyAvailable: Bool

    public init(
        dataSource: ClaudeUsageDataSource,
        inclusionReason: ClaudeSourcePlanReason,
        isPlausiblyAvailable: Bool)
    {
        self.dataSource = dataSource
        self.inclusionReason = inclusionReason
        self.isPlausiblyAvailable = isPlausiblyAvailable
    }
}

public struct ClaudeFetchPlan: Equatable, Sendable {
    public let input: ClaudeSourcePlanningInput
    public let orderedSteps: [ClaudeFetchPlanStep]

    public init(input: ClaudeSourcePlanningInput, orderedSteps: [ClaudeFetchPlanStep]) {
        self.input = input
        self.orderedSteps = orderedSteps
    }

    public var availableSteps: [ClaudeFetchPlanStep] {
        self.orderedSteps.filter(\.isPlausiblyAvailable)
    }

    public var isNoSourceAvailable: Bool {
        self.availableSteps.isEmpty
    }

    public var preferredStep: ClaudeFetchPlanStep? {
        switch self.input.selectedDataSource {
        case .auto:
            self.availableSteps.first
        case .oauth, .web, .cli:
            self.orderedSteps.first
        }
    }

    public var executionSteps: [ClaudeFetchPlanStep] {
        switch self.input.selectedDataSource {
        case .auto:
            self.availableSteps
        case .oauth, .web, .cli:
            self.orderedSteps
        }
    }

    public var compatibilityStrategy: ClaudeUsageStrategy? {
        guard let preferredStep else { return nil }
        let useWebExtras = self.input.runtime == .app
            && preferredStep.dataSource == .cli
            && self.input.webExtrasEnabled
        return ClaudeUsageStrategy(
            dataSource: preferredStep.dataSource,
            useWebExtras: useWebExtras)
    }

    public var orderLabel: String {
        self.orderedSteps.map(\.dataSource.sourceLabel).joined(separator: "→")
    }

    public func debugLines() -> [String] {
        var lines = ["planner_order=\(self.orderLabel)"]
        lines.append("planner_selected=\(self.preferredStep?.dataSource.rawValue ?? "none")")
        lines.append("planner_no_source=\(self.isNoSourceAvailable)")
        for step in self.orderedSteps {
            let availability = step.isPlausiblyAvailable ? "available" : "unavailable"
            lines.append(
                "planner_step.\(step.dataSource.rawValue)=\(availability) reason=\(step.inclusionReason.rawValue)")
        }
        return lines
    }
}

public enum ClaudeCLIResolver {
    #if DEBUG
    @TaskLocal static var resolvedBinaryPathOverrideForTesting: String?

    public static var currentResolvedBinaryPathOverrideForTesting: String? {
        self.resolvedBinaryPathOverrideForTesting
    }

    public static func withResolvedBinaryPathOverrideForTesting<T>(
        _ path: String?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$resolvedBinaryPathOverrideForTesting.withValue(path) {
            try await operation()
        }
    }
    #endif

    public static func resolvedBinaryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current)
        -> String?
    {
        #if DEBUG
        if let override = self.resolvedBinaryPathOverrideForTesting {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        #endif

        var normalizedEnvironment = environment
        if let override = environment["CLAUDE_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if override.isEmpty {
                normalizedEnvironment.removeValue(forKey: "CLAUDE_CLI_PATH")
            } else {
                normalizedEnvironment["CLAUDE_CLI_PATH"] = override
                if FileManager.default.isExecutableFile(atPath: override) {
                    return override
                }
            }
        }

        return BinaryLocator.resolveClaudeBinary(
            env: normalizedEnvironment,
            loginPATH: loginPATH)
    }

    public static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        self.resolvedBinaryPath(environment: environment) != nil
    }
}

public enum ClaudeSourcePlanner {
    public static func resolve(input: ClaudeSourcePlanningInput) -> ClaudeFetchPlan {
        ClaudeFetchPlan(input: input, orderedSteps: self.makeSteps(input: input))
    }

    private static func makeSteps(input: ClaudeSourcePlanningInput) -> [ClaudeFetchPlanStep] {
        switch input.selectedDataSource {
        case .auto:
            switch input.runtime {
            case .app:
                [
                    self.step(.oauth, reason: .appAutoPreferredOAuth, input: input),
                    self.step(.cli, reason: .appAutoFallbackCLI, input: input),
                    self.step(.web, reason: .appAutoFallbackWeb, input: input),
                ]
            case .cli:
                [
                    self.step(.web, reason: .cliAutoPreferredWeb, input: input),
                    self.step(.cli, reason: .cliAutoFallbackCLI, input: input),
                ]
            }
        case .oauth:
            [self.step(.oauth, reason: .explicitSourceSelection, input: input)]
        case .web:
            [self.step(.web, reason: .explicitSourceSelection, input: input)]
        case .cli:
            [self.step(.cli, reason: .explicitSourceSelection, input: input)]
        }
    }

    private static func step(
        _ dataSource: ClaudeUsageDataSource,
        reason: ClaudeSourcePlanReason,
        input: ClaudeSourcePlanningInput) -> ClaudeFetchPlanStep
    {
        ClaudeFetchPlanStep(
            dataSource: dataSource,
            inclusionReason: reason,
            isPlausiblyAvailable: self.isPlausiblyAvailable(dataSource, input: input))
    }

    private static func isPlausiblyAvailable(
        _ dataSource: ClaudeUsageDataSource,
        input: ClaudeSourcePlanningInput) -> Bool
    {
        switch dataSource {
        case .auto:
            false
        case .oauth:
            input.hasOAuthCredentials
        case .web:
            input.hasWebSession
        case .cli:
            input.hasCLI
        }
    }
}
