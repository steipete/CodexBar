#if canImport(JavaScriptCore)
import Foundation

public enum ProviderPluginPrototype {
    public static let environmentKey = "CODEXBAR_JS_PROVIDERS"

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[self.environmentKey] == "1"
    }
}

public final class ScriptFetchStrategy: ProviderFetchStrategy, @unchecked Sendable {
    public typealias SecretResolver = @Sendable ([String: String]) -> String?
    public struct Values: Sendable {
        public let settings: [String: String]
        public let secrets: [String: String]

        public init(settings: [String: String] = [:], secrets: [String: String] = [:]) {
            self.settings = settings
            self.secrets = secrets
        }
    }

    public typealias ValuesResolver = @Sendable (ProviderFetchContext) -> Values?
    public typealias EnabledResolver = @Sendable ([String: String]) -> Bool

    public let id: String
    public let kind: ProviderFetchKind

    private let provider: UsageProvider
    private let bundledPlugin: String
    private let secretKey: String?
    private let resolveValues: ValuesResolver
    private let isEnabled: EnabledResolver
    private let transport: any ProviderHTTPTransport
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var runtime: ProviderPluginRuntime?

    public init(
        id: String,
        provider: UsageProvider,
        bundledPlugin: String,
        secretKey: String,
        kind: ProviderFetchKind = .apiToken,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        resolveSecret: @escaping SecretResolver,
        isEnabled: @escaping EnabledResolver = { ProviderPluginPrototype.isEnabled(environment: $0) })
    {
        self.id = id
        self.provider = provider
        self.bundledPlugin = bundledPlugin
        self.kind = kind
        self.secretKey = secretKey
        self.transport = transport
        self.timeout = timeout
        self.resolveValues = { context in
            guard let secret = resolveSecret(context.env) else { return nil }
            return Values(secrets: [secretKey: secret])
        }
        self.isEnabled = isEnabled
    }

    public init(
        id: String,
        provider: UsageProvider,
        bundledPlugin: String,
        secretKey: String? = nil,
        kind: ProviderFetchKind = .apiToken,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        resolveValues: @escaping ValuesResolver,
        isEnabled: @escaping EnabledResolver = { ProviderPluginPrototype.isEnabled(environment: $0) })
    {
        self.id = id
        self.provider = provider
        self.bundledPlugin = bundledPlugin
        self.kind = kind
        self.secretKey = secretKey
        self.transport = transport
        self.timeout = timeout
        self.resolveValues = resolveValues
        self.isEnabled = isEnabled
    }

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard self.isEnabled(context.env), let values = self.resolveValues(context) else { return false }
        guard let secretKey else { return true }
        return values.secrets[secretKey]?.isEmpty == false
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard self.isEnabled(context.env) else {
            throw ProviderPluginError.load("JavaScript provider prototype is disabled")
        }
        guard let values = self.resolveValues(context) else {
            throw ProviderPluginError.secretAccess("required provider secret is unavailable")
        }
        if let secretKey, values.secrets[secretKey]?.isEmpty != false {
            throw ProviderPluginError.secretAccess("required provider secret is unavailable")
        }
        let runtime = try self.loadedRuntime()
        guard runtime.manifest.id == self.provider.instanceID else {
            throw ProviderPluginError.invalidManifest(
                "bundled plugin id '\(runtime.manifest.id.rawValue)' does not match '\(self.provider.rawValue)'")
        }
        let usage = try await runtime.fetchUsage(
            settings: values.settings,
            secrets: values.secrets,
            cookieResolver: ProviderPluginCookieBroker.resolver(context: context))
        return self.makeResult(usage: usage, sourceLabel: "js")
    }

    public func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private func loadedRuntime() throws -> ProviderPluginRuntime {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let runtime = self.runtime {
            return runtime
        }
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: self.bundledPlugin,
            transport: self.transport,
            timeout: self.timeout)
        self.runtime = runtime
        return runtime
    }
}

extension ProviderFetchPlan {
    struct ScriptPrototypeAPIConfiguration: Sendable {
        let provider: UsageProvider
        let plugin: String
        let secretKey: String
        let strategyID: String
        let sourceLabel: String
        let reportsMissingCredentials: Bool

        init(
            provider: UsageProvider,
            plugin: String,
            secretKey: String,
            strategyID: String,
            sourceLabel: String = "api",
            reportsMissingCredentials: Bool = false)
        {
            self.provider = provider
            self.plugin = plugin
            self.secretKey = secretKey
            self.strategyID = strategyID
            self.sourceLabel = sourceLabel
            self.reportsMissingCredentials = reportsMissingCredentials
        }
    }

    static func scriptPrototypeAPI(
        configuration: ScriptPrototypeAPIConfiguration,
        resolveToken: @escaping APITokenFetchStrategy.TokenResolver,
        missingCredentialsError: @escaping APITokenFetchStrategy.MissingCredentialsError,
        loadUsage: @escaping APITokenFetchStrategy.UsageLoader) -> ProviderFetchPlan
    {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let swift = APITokenFetchStrategy(
                    id: configuration.strategyID,
                    sourceLabel: configuration.sourceLabel,
                    reportsMissingCredentials: configuration.reportsMissingCredentials,
                    resolveToken: resolveToken,
                    missingCredentialsError: missingCredentialsError,
                    loadUsage: loadUsage)
                guard ProviderPluginPrototype.isEnabled(environment: context.env) else {
                    return [swift]
                }
                return [
                    ScriptFetchStrategy(
                        id: "\(configuration.provider.rawValue).js",
                        provider: configuration.provider,
                        bundledPlugin: configuration.plugin,
                        secretKey: configuration.secretKey,
                        resolveSecret: resolveToken),
                    swift,
                ]
            }))
    }
}
#endif
