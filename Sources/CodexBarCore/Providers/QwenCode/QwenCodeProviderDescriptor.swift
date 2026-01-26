import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum QwenCodeProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .qwencode,
            metadata: ProviderMetadata(
                id: .qwencode,
                displayName: "Qwen Code",
                sessionLabel: "Requests",
                weeklyLabel: "Tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Qwen Code usage",
                cliName: "qwen",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://chat.qwen.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .qwencode,
                iconResourceName: "ProviderIcon-qwencode",
                color: ProviderColor(red: 32 / 255, green: 140 / 255, blue: 220 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Qwen Code cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [QwenCodeLocalFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "qwen",
                aliases: ["qwen-code"],
                versionDetector: { _ in ProviderVersionDetector.qwenVersion() }))
    }
}

struct QwenCodeLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "qwencode.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let baseDirectory = QwenCodeUsageProbe.resolveBaseDirectory(env: context.env)
        return QwenCodeUsageProbe.projectsDirectoryExists(baseDirectory: baseDirectory)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let baseDirectory = QwenCodeUsageProbe.resolveBaseDirectory(env: context.env)
        let requestLimit = Self.resolveRequestLimit(settings: context.settings, env: context.env)
        let probe = QwenCodeUsageProbe(requestLimit: requestLimit, baseDirectory: baseDirectory)
        let snapshot = try probe.fetch()
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(requestLimit: requestLimit),
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveRequestLimit(settings: ProviderSettingsSnapshot?, env: [String: String]) -> Int {
        if let override = env["CODEXBAR_QWENCODE_DAILY_REQUEST_LIMIT"],
           let limit = Int(override.trimmingCharacters(in: .whitespacesAndNewlines)),
           limit > 0
        {
            return limit
        }

        if let limit = settings?.qwencode?.dailyRequestLimit, limit > 0 {
            return limit
        }

        return QwenCodeUsageProbe.defaultDailyRequestLimit
    }
}
