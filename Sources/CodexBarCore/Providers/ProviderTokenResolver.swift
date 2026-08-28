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

    public static func token(
        for provider: UsageProvider,
        kind: ProviderCredentialResolutionKind = .primary,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil) -> String?
    {
        self.resolution(
            for: provider,
            kind: kind,
            environment: environment,
            authFileURL: authFileURL)?.token
    }
}
