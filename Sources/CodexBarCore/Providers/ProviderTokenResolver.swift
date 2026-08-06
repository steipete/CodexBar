import Foundation

public enum ProviderTokenSource: String, Sendable {
    case environment
    case authFile
}

public struct ProviderTokenResolution: Sendable {
    public let token: String
    public let source: ProviderTokenSource

    public init(token: String, source: ProviderTokenSource) {
        self.token = token
        self.source = source
    }
}

public enum ProviderTokenResolver {
    public static func resolution(
        for provider: UsageProvider,
        kind: ProviderCredentialResolutionKind = .primary,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil) -> ProviderTokenResolution?
    {
        ProviderDescriptorRegistry.descriptor(for: provider).credentials?.resolveToken(
            kind: kind,
            environment: environment,
            authFileURL: authFileURL)
    }

    public static func ampToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.ampResolution(environment: environment)?.token
    }

    public static func zaiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.zaiResolution(environment: environment)?.token
    }

    public static func syntheticToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.syntheticResolution(environment: environment)?.token
    }

    public static func openAIAPIToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.openAIAPIResolution(environment: environment)?.token
    }

    public static func azureOpenAIToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.azureOpenAIResolution(environment: environment)?.token
    }

    public static func claudeAdminAPIToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.claudeAdminAPIResolution(environment: environment)?.token
    }

    public static func clinePassToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.clinePassResolution(environment: environment)?.token
    }

    public static func copilotToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.copilotResolution(environment: environment)?.token
    }

    public static func minimaxToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.minimaxTokenResolution(environment: environment)?.token
    }

    public static func alibabaToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.alibabaTokenResolution(environment: environment)?.token
    }

    public static func minimaxCookie(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.minimaxCookieResolution(environment: environment)?.token
    }

    public static func kimiAuthToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.kimiAuthResolution(environment: environment)?.token
    }

    public static func kimiAPIToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.kimiAPIResolution(environment: environment)?.token
    }

    public static func moonshotToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.moonshotResolution(environment: environment)?.token
    }

    public static func ollamaToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.ollamaResolution(environment: environment)?.token
    }

    public static func kiloToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil) -> String?
    {
        self.kiloResolution(environment: environment, authFileURL: authFileURL)?.token
    }

    public static func warpToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.warpResolution(environment: environment)?.token
    }

    public static func openRouterToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.openRouterResolution(environment: environment)?.token
    }

    public static func elevenLabsToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.elevenLabsResolution(environment: environment)?.token
    }

    public static func neuralWattToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.neuralWattResolution(environment: environment)?.token
    }

    public static func groqToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.groqResolution(environment: environment)?.token
    }

    public static func llmProxyToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.llmProxyResolution(environment: environment)?.token
    }

    public static func liteLLMToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.liteLLMResolution(environment: environment)?.token
    }

    public static func clawRouterToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.clawRouterResolution(environment: environment)?.token
    }

    public static func perplexitySessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.perplexityResolution(environment: environment)?.token
    }

    public static func deepseekToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.deepseekResolution(environment: environment)?.token
    }

    public static func poeToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.poeResolution(environment: environment)?.token
    }

    public static func crofToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.crofResolution(environment: environment)?.token
    }

    public static func veniceToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.veniceResolution(environment: environment)?.token
    }

    public static func deepInfraToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.deepInfraResolution(environment: environment)?.token
    }

    public static func stepfunToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.stepfunResolution(environment: environment)?.token
    }

    public static func doubaoToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.doubaoResolution(environment: environment)?.token
    }

    public static func bedrockAccessKeyID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.bedrockResolution(environment: environment)?.token
    }

    public static func bedrockResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .bedrock, environment: environment)
    }

    public static func ampResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .amp, environment: environment)
    }

    public static func deepseekResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .deepseek, environment: environment)
    }

    public static func deepInfraResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .deepinfra, environment: environment)
    }

    public static func poeResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .poe, environment: environment)
    }

    public static func crofResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .crof, environment: environment)
    }

    public static func veniceResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .venice, environment: environment)
    }

    public static func codebuffToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil) -> String?
    {
        self.codebuffResolution(environment: environment, authFileURL: authFileURL)?.token
    }

    public static func stepfunResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .stepfun, environment: environment)
    }

    public static func doubaoResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .doubao, environment: environment)
    }

    public static func zaiResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .zai, environment: environment)
    }

    public static func syntheticResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .synthetic, environment: environment)
    }

    public static func openAIAPIResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .openai, environment: environment)
    }

    public static func azureOpenAIResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .azureopenai, environment: environment)
    }

    public static func claudeAdminAPIResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .claude, environment: environment)
    }

    public static func clinePassResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .clinepass, environment: environment)
    }

    public static func copilotResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .copilot, environment: environment)
    }

    public static func minimaxTokenResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .minimax, environment: environment)
    }

    public static func alibabaTokenResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .alibaba, environment: environment)
    }

    public static func minimaxCookieResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .minimax, kind: .secondary, environment: environment)
    }

    public static func kimiAuthResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .kimi, environment: environment)
    }

    public static func kimiAPIResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .kimi, kind: .secondary, environment: environment)
    }

    public static func moonshotResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .moonshot, environment: environment)
    }

    public static func ollamaResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .ollama, environment: environment)
    }

    public static func kiloResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil) -> ProviderTokenResolution?
    {
        self.resolution(for: .kilo, environment: environment, authFileURL: authFileURL)
    }

    public static func warpResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .warp, environment: environment)
    }

    public static func openRouterResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .openrouter, environment: environment)
    }

    public static func elevenLabsResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .elevenlabs, environment: environment)
    }

    public static func neuralWattResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .neuralwatt, environment: environment)
    }

    public static func groqResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .groq, environment: environment)
    }

    public static func llmProxyResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .llmproxy, environment: environment)
    }

    public static func liteLLMResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .litellm, environment: environment)
    }

    public static func clawRouterResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .clawrouter, environment: environment)
    }

    public enum DeepgramCredentialKind: Sendable {
        case apiKey
        case projectID
    }

    public static func deepgramResolution(
        type: DeepgramCredentialKind,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        switch type {
        case .apiKey:
            self.resolution(for: .deepgram, environment: environment)?.token

        case .projectID:
            self.resolution(for: .deepgram, kind: .projectID, environment: environment)?.token
        }
    }

    public static func codebuffResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil) -> ProviderTokenResolution?
    {
        self.resolution(for: .codebuff, environment: environment, authFileURL: authFileURL)
    }

    public static func perplexityResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolution(for: .perplexity, environment: environment)
    }
}
