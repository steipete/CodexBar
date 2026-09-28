import Foundation

public enum ProviderPluginPrototype {
    public static let environmentKey = "CODEXBAR_JS_PROVIDERS"

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[self.environmentKey] == "1"
    }
}

public final class ScriptFetchStrategy: ProviderFetchStrategy, @unchecked Sendable {
    public typealias CookieImport = @Sendable (ProviderFetchContext, String, Int) throws
        -> [(header: String, source: String)]?
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
    public typealias ContextValidator = @Sendable (ProviderFetchContext) throws -> Void
    public typealias EnabledResolver = @Sendable ([String: String]) -> Bool
    public typealias CookieSettingsResolver = @Sendable (ProviderFetchContext)
        -> ProviderSettingsSnapshot.CookieProviderSettings

    public let id: String
    public let kind: ProviderFetchKind

    private let cookieImport: CookieImport?
    private let cookieSettings: CookieSettingsResolver?
    private let provider: UsageProvider
    private let bundledPlugin: String
    private let sourceLabel: String
    private let secretKey: String?
    private let resolveValues: ValuesResolver
    private let validateContext: ContextValidator
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
        sourceLabel: String = "js",
        kind: ProviderFetchKind = .apiToken,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        validateContext: @escaping ContextValidator = { _ in },
        resolveSecret: @escaping SecretResolver,
        isEnabled: @escaping EnabledResolver = { ProviderPluginPrototype.isEnabled(environment: $0) })
    {
        self.id = id
        self.provider = provider
        self.bundledPlugin = bundledPlugin
        self.sourceLabel = sourceLabel
        self.kind = kind
        self.secretKey = secretKey
        self.cookieImport = nil
        self.cookieSettings = nil
        self.transport = transport
        self.timeout = timeout
        self.validateContext = validateContext
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
        sourceLabel: String = "js",
        kind: ProviderFetchKind = .apiToken,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        validateContext: @escaping ContextValidator = { _ in },
        cookieImport: CookieImport? = nil,
        cookieSettings: CookieSettingsResolver? = nil,
        resolveValues: @escaping ValuesResolver,
        isEnabled: @escaping EnabledResolver = { ProviderPluginPrototype.isEnabled(environment: $0) })
    {
        self.id = id
        self.provider = provider
        self.bundledPlugin = bundledPlugin
        self.sourceLabel = sourceLabel
        self.kind = kind
        self.secretKey = secretKey
        self.transport = transport
        self.timeout = timeout
        self.validateContext = validateContext
        self.cookieImport = cookieImport
        self.cookieSettings = cookieSettings
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
        try self.validateContext(context)
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
        let importer: ProviderPluginCookieBroker.BatchImporter? = if let importCookies = self.cookieImport {
            { domain, batch in try importCookies(context, domain, batch) }
        } else {
            nil
        }
        let cookies = ProviderPluginCookieBroker(
            provider: self.provider,
            domains: runtime.manifest.cookieDomains,
            context: context,
            importer: importer,
            policy: runtime.manifest.cookiePolicy,
            settingsOverride: self.cookieSettings?(context))
        let result = try await runtime.fetchResult(
            settings: values.settings,
            secrets: values.secrets,
            sourceMode: context.sourceMode,
            cookieSource: cookies.cookieSource,
            cookieInvalidator: { cookies.rejectCookie(domain: $0) },
            cookieSessionResolver: { try cookies.nextSession(domain: $0, cachedOnly: $1) },
            cookieSessionInvalidator: { cookies.rejectCookie(domain: $0, id: $1) },
            cookieSessionValidator: { try cookies.acceptCookie(domain: $0, id: $1) },
            cookieResolver: { _, domain in try cookies.cookieHeader(domain: domain) })
        try Task.checkCancellation()
        let saved = result.persist.isEmpty ? ProviderSettingsSaveOutcome.unchanged
            : await context.settingsWriter?(self.provider, result.persist) ?? .failed
        try Task.checkCancellation()
        return self.makeResult(
            usage: result.usage, sourceLabel: result.sourceLabel ?? self.sourceLabel, diagnostic: saved.diagnostic)
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
