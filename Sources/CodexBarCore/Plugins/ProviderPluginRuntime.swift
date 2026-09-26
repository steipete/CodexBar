import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore
#endif

public final class ProviderPluginRuntime: @unchecked Sendable {
    public typealias CookieInvalidator = @Sendable (String) -> Void
    public typealias CookieSessionResolver = @Sendable (String, Bool) async throws -> ProviderPluginCookieSession?
    public typealias CookieSessionInvalidator = @Sendable (String, String) -> Void
    public typealias CookieResolver = @Sendable (UsageProvider, String) async throws -> String
    public typealias InstanceCookieResolver = @Sendable (ProviderInstanceID, String) async throws -> String

    public static let defaultTimeout: TimeInterval = 20
    public static let maximumResponseBytes = 5 * 1024 * 1024
    public static let engineEnvironmentKey = "CODEXBAR_PLUGIN_ENGINE"
    public static let javaScriptCoreRollbackDefaultsKey = "debugUseJavaScriptCorePluginEngine"

    public let manifest: ProviderPluginManifest

    private let source: String
    private let preludeSource: String
    private let transport: any ProviderHTTPTransport
    private let timeout: TimeInterval
    private let responseSizeLimit: Int
    private let enforcesUserResponsePolicy: Bool
    private let allowsDynamicID: Bool
    private let contextOptions: ProviderPluginContextOptions
    private let engineKind: ProviderPluginEngineKind
    private let storage: ProviderPluginStorage?
    private let lock = NSLock()
    private var worker: (any ProviderPluginEngine)?

    public convenience init(
        bundledPlugin name: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout) throws
    {
        try self.init(
            bundledPlugin: name,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: transport,
            timeout: timeout)
    }

    convenience init(
        bundledPlugin name: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        contextOptions: ProviderPluginContextOptions) throws
    {
        try self.init(
            bundledPlugin: name,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: transport,
            timeout: timeout,
            contextOptions: contextOptions)
    }

    convenience init(
        bundledPlugin name: String,
        resourceBundle: Bundle?,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        contextOptions: ProviderPluginContextOptions = .production) throws
    {
        guard let resourceBundle else {
            throw ProviderPluginError.load(CodexBarCoreResources.missingBundleMessage)
        }
        guard let url = resourceBundle.url(forResource: name, withExtension: "js") else {
            throw ProviderPluginError.load("bundled plugin '\(name).js' was not found")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        try ProviderPluginSourceLint.validateBundled(source, name: name)
        try self.init(
            source: source,
            resourceBundle: resourceBundle,
            transport: transport,
            timeout: timeout,
            contextOptions: contextOptions)
    }

    public convenience init(
        source: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        responseSizeLimit: Int = ProviderPluginRuntime.maximumResponseBytes,
        enforcesUserResponsePolicy: Bool = false,
        allowsDynamicID: Bool = false,
        engine: ProviderPluginEngineKind = .automatic,
        storageDirectory: URL? = nil) throws
    {
        try self.init(
            source: source,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: transport,
            timeout: timeout,
            responseSizeLimit: responseSizeLimit,
            enforcesUserResponsePolicy: enforcesUserResponsePolicy,
            allowsDynamicID: allowsDynamicID,
            contextOptions: .production,
            engine: engine,
            storageDirectory: storageDirectory)
    }

    init(
        source: String,
        resourceBundle: Bundle?,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        responseSizeLimit: Int = ProviderPluginRuntime.maximumResponseBytes,
        enforcesUserResponsePolicy: Bool = false,
        allowsDynamicID: Bool = false,
        contextOptions: ProviderPluginContextOptions = .production,
        engine: ProviderPluginEngineKind = .automatic,
        storageDirectory: URL? = nil) throws
    {
        guard timeout > 0 else { throw ProviderPluginError.load("timeout must be positive") }
        guard responseSizeLimit > 0 else { throw ProviderPluginError.load("response size limit must be positive") }
        if let optionalRequestTimeoutSeconds = contextOptions.optionalRequestTimeoutSeconds,
           !(1...30).contains(optionalRequestTimeoutSeconds)
        {
            throw ProviderPluginError.load("optional request timeout must be from 1 through 30 seconds")
        }
        guard let resourceBundle else {
            throw ProviderPluginError.load(CodexBarCoreResources.missingBundleMessage)
        }
        guard let preludeURL = resourceBundle.url(
            forResource: "provider-plugin-prelude",
            withExtension: "js")
        else {
            throw ProviderPluginError.load("provider plugin prelude was not found")
        }

        self.source = source
        self.preludeSource = try String(contentsOf: preludeURL, encoding: .utf8)
        self.transport = transport
        self.timeout = timeout
        self.responseSizeLimit = responseSizeLimit
        self.enforcesUserResponsePolicy = enforcesUserResponsePolicy
        self.allowsDynamicID = allowsDynamicID
        self.contextOptions = contextOptions
        self.engineKind = Self.resolveEngineKind(engine)

        let worker = try ProviderPluginEngineFactory.make(
            kind: self.engineKind,
            source: source,
            preludeSource: self.preludeSource,
            transport: transport,
            timeout: timeout,
            responseSizeLimit: responseSizeLimit,
            enforcesUserResponsePolicy: enforcesUserResponsePolicy,
            allowsDynamicID: allowsDynamicID)
        self.worker = worker
        self.manifest = worker.manifest
        self.storage = worker.manifest.capabilities.contains(.persistentStorage)
            ? ProviderPluginStorage(
                directory: storageDirectory ?? ProviderPluginStorage.defaultDirectory,
                instanceID: worker.manifest.id)
            : nil
    }

    public func fetchUsage(
        settings: [String: String] = [:],
        secrets: [String: String] = [:],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        sourceMode: ProviderSourceMode = .auto,
        cookieSource: ProviderCookieSource = .auto,
        cookieInvalidator: CookieInvalidator? = nil,
        cookieSessionResolver: CookieSessionResolver? = nil,
        cookieSessionInvalidator: CookieSessionInvalidator? = nil,
        cookieResolver: CookieResolver? = nil,
        instanceCookieResolver: InstanceCookieResolver? = nil) async throws -> UsageSnapshot
    {
        try await self.fetchResult(
            settings: settings,
            secrets: secrets,
            now: now,
            timeZone: timeZone,
            sourceMode: sourceMode,
            cookieSource: cookieSource,
            cookieInvalidator: cookieInvalidator,
            cookieSessionResolver: cookieSessionResolver,
            cookieSessionInvalidator: cookieSessionInvalidator,
            cookieResolver: cookieResolver,
            instanceCookieResolver: instanceCookieResolver).usage
    }

    public func fetchResult(
        settings: [String: String] = [:],
        secrets: [String: String] = [:],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        sourceMode: ProviderSourceMode = .auto,
        cookieSource: ProviderCookieSource = .auto,
        cookieInvalidator: CookieInvalidator? = nil,
        cookieSessionResolver: CookieSessionResolver? = nil,
        cookieSessionInvalidator: CookieSessionInvalidator? = nil,
        cookieResolver: CookieResolver? = nil,
        instanceCookieResolver: InstanceCookieResolver? = nil) async throws -> ProviderPluginResult
    {
        let sanitizedSettings = settings.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sanitizedSecrets = secrets.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let auth = self.manifest.auth,
           sanitizedSecrets[auth.secret]?.isEmpty != false
        {
            throw ProviderPluginError.secretAccess("required secret '\(auth.secret)' is unavailable")
        }

        var contextOptions = self.contextOptions
        contextOptions.storage = self.storage
        contextOptions.cookieSource = sourceMode.usesWeb ? cookieSource : .off
        contextOptions.cookieInvalidator = cookieInvalidator
        contextOptions.cookieSessionResolver = cookieSessionResolver ?? ProviderPluginCookieSession.legacyResolver(
            provider: self.manifest.id,
            source: cookieSource,
            resolver: cookieResolver,
            instanceResolver: instanceCookieResolver)
        contextOptions.cookieSessionInvalidator = cookieSessionInvalidator
        let worker = try self.currentWorker()
        let gate = ProviderPluginCompletionGate<ProviderPluginResult>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { return }
                worker.fetch(
                    settings: sanitizedSettings,
                    secrets: sanitizedSecrets,
                    now: now,
                    timeZone: timeZone,
                    contextOptions: contextOptions,
                    cookieResolver: cookieResolver,
                    instanceCookieResolver: instanceCookieResolver)
                { result in
                    gate.finish(result.mapError { self.redactedError($0, secrets: sanitizedSecrets.values) })
                }
                Task.detached { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    let nanoseconds = UInt64(self.timeout * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    if gate.finish(.failure(ProviderPluginError.timedOut)) {
                        worker.requestInterrupt()
                        self.discard(worker)
                    }
                }
            }
        } onCancel: {
            if gate.finish(.failure(CancellationError())) {
                worker.requestInterrupt()
                self.discard(worker)
            }
        }
    }

    func removePersistentStorage() throws {
        try self.storage?.removeAll()
    }

    public func globalType(of name: String) throws -> String {
        try self.currentWorker().globalType(of: name)
    }

    private func currentWorker() throws -> any ProviderPluginEngine {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let worker = self.worker {
            return worker
        }
        let worker = try ProviderPluginEngineFactory.make(
            kind: self.engineKind,
            source: self.source,
            preludeSource: self.preludeSource,
            transport: self.transport,
            timeout: self.timeout,
            responseSizeLimit: self.responseSizeLimit,
            enforcesUserResponsePolicy: self.enforcesUserResponsePolicy,
            allowsDynamicID: self.allowsDynamicID)
        guard worker.manifest.id == self.manifest.id else {
            throw ProviderPluginError.load("reloaded plugin changed provider id")
        }
        self.worker = worker
        return worker
    }

    private func discard(_ worker: any ProviderPluginEngine) {
        self.lock.lock()
        if let current = self.worker, current === worker {
            self.worker = nil
        }
        self.lock.unlock()
    }

    static func resolveEngineKind(_ requested: ProviderPluginEngineKind) -> ProviderPluginEngineKind {
        self.resolveEngineKind(
            requested,
            environment: ProcessInfo.processInfo.environment,
            useJavaScriptCoreRollback: UserDefaults.standard.bool(forKey: self.javaScriptCoreRollbackDefaultsKey))
    }

    static func resolveEngineKind(
        _ requested: ProviderPluginEngineKind,
        environment: [String: String],
        useJavaScriptCoreRollback: Bool) -> ProviderPluginEngineKind
    {
        guard requested == .automatic else { return requested }
        #if canImport(JavaScriptCore)
        switch environment[self.engineEnvironmentKey]?.lowercased() {
        case "jsc": return .javaScriptCore
        case "quickjs": return .quickJS
        default:
            if useJavaScriptCoreRollback {
                return .javaScriptCore
            }
        }
        #endif
        return .quickJS
    }

    private func redactedError(_ error: Error, secrets: Dictionary<String, String>.Values) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? URLError { return URLError(error.code) }
        var message = error.localizedDescription
        for secret in secrets where !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: "<redacted>")
        }
        if let pluginError = error as? ProviderPluginError {
            switch pluginError {
            case .timedOut: return pluginError
            case .load: return ProviderPluginError.load(message.removingPluginErrorPrefix)
            case .invalidManifest: return ProviderPluginError.invalidManifest(message.removingPluginErrorPrefix)
            case .networkPolicy: return ProviderPluginError.networkPolicy(message.removingPluginErrorPrefix)
            case .http: return ProviderPluginError.http(message.removingPluginErrorPrefix)
            case .secretAccess: return ProviderPluginError.secretAccess(message.removingPluginErrorPrefix)
            case .invalidSnapshot: return ProviderPluginError.invalidSnapshot(message.removingPluginErrorPrefix)
            case .script: return ProviderPluginError.script(message.removingPluginErrorPrefix)
            }
        }
        if let classifiedError = error as? ProviderFetchClassifiedError {
            return ProviderFetchClassifiedError(
                kind: classifiedError.kind,
                message: message,
                retryAfterSeconds: classifiedError.retryAfterSeconds)
        }
        return ProviderPluginError.script(message)
    }
}

extension String {
    fileprivate var removingPluginErrorPrefix: String {
        guard let separator = self.firstIndex(of: ":") else { return self }
        return String(self[self.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }
}

private final class ProviderPluginCompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        self.lock.lock()
        if let result = self.pendingResult {
            self.pendingResult = nil
            self.lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        self.lock.unlock()
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        self.lock.lock()
        guard !self.finished else {
            self.lock.unlock()
            return false
        }
        self.finished = true
        guard let continuation = self.continuation else {
            self.pendingResult = result
            self.lock.unlock()
            return true
        }
        self.continuation = nil
        self.lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

#if canImport(JavaScriptCore)
private final class ProviderPluginJSValueBox: @unchecked Sendable {
    let value: JSValue

    init(_ value: JSValue) {
        self.value = value
    }
}

private struct ProviderPluginHTTPRequestCallbacks: @unchecked Sendable {
    let wantsJSON: Bool
    let resolve: ProviderPluginJSValueBox
    let reject: ProviderPluginJSValueBox
}

final class JavaScriptCoreProviderPluginEngine: ProviderPluginEngine, @unchecked Sendable {
    private typealias HTTPBlock = @convention(block) (String, JSValue, String, Bool, JSValue, JSValue) -> Void
    private typealias CookieBlock = @convention(block) (String, Bool, JSValue, JSValue) -> Void

    let manifest: ProviderPluginManifest

    private let queue: DispatchQueue
    private let context: JSContext
    private let applyPrelude: JSValue
    private let fetchUsage: JSValue
    private let keyEnumerator: JSValue
    private let transport: any ProviderHTTPTransport
    private let responseSizeLimit: Int
    private let enforcesUserResponsePolicy: Bool
    private var cache: [String: (value: JSValue, expiresAt: Date)] = [:]
    private var retainedCallbacks: [UUID: [Any]] = [:]
    private let requestLock = NSLock()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var interrupted = false

    /// Opt-in relaxes only the status gate, never the representation gate.
    private var rejectsNonSuccessResponses: Bool {
        self.enforcesUserResponsePolicy && !self.manifest.capabilities.contains(.httpStatus)
    }

    // swiftlint:disable:next function_parameter_count
    static func make(
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        responseSizeLimit: Int,
        enforcesUserResponsePolicy: Bool,
        allowsDynamicID: Bool) throws -> JavaScriptCoreProviderPluginEngine
    {
        let queue = DispatchQueue(label: "com.steipete.codexbar.provider-plugin.\(UUID().uuidString)")
        return try queue.sync {
            try JavaScriptCoreProviderPluginEngine(
                queue: queue,
                source: source,
                preludeSource: preludeSource,
                transport: transport,
                responseSizeLimit: responseSizeLimit,
                enforcesUserResponsePolicy: enforcesUserResponsePolicy,
                allowsDynamicID: allowsDynamicID)
        }
    }

    private init(
        queue: DispatchQueue,
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        responseSizeLimit: Int,
        enforcesUserResponsePolicy: Bool,
        allowsDynamicID: Bool) throws
    {
        guard let context = JSContext() else {
            throw ProviderPluginError.load("JavaScriptCore could not create a context")
        }
        guard let keyEnumerator = context.evaluateScript("Reflect.ownKeys") else {
            throw ProviderPluginError.load("JavaScriptCore key enumeration is unavailable")
        }
        self.keyEnumerator = keyEnumerator
        self.queue = queue
        self.context = context
        self.transport = transport
        self.responseSizeLimit = responseSizeLimit
        self.enforcesUserResponsePolicy = enforcesUserResponsePolicy

        var definition: JSValue?
        let defineProvider: @convention(block) (JSValue) -> Void = { value in
            definition = value
        }
        context.setObject(defineProvider, forKeyedSubscript: "defineProvider" as NSString)

        context.exception = nil
        guard let applyPrelude = context.evaluateScript(preludeSource), context.exception == nil else {
            throw ProviderPluginError.load(Self.exceptionMessage(context) ?? "prelude evaluation failed")
        }
        self.applyPrelude = applyPrelude

        context.exception = nil
        _ = context.evaluateScript(source)
        if let message = Self.exceptionMessage(context) {
            throw ProviderPluginError.load(message)
        }
        guard let definition else {
            throw ProviderPluginError.invalidManifest("plugin did not call defineProvider(...)")
        }
        guard let fetchUsage = definition.forProperty("fetchUsage"), fetchUsage.isObject else {
            throw ProviderPluginError.invalidManifest("'fetchUsage' must be a function")
        }
        self.fetchUsage = fetchUsage
        self.manifest = try ProviderPluginManifest(
            definition: JavaScriptCorePluginValue(definition, keyEnumerator: self.keyEnumerator),
            allowsDynamicID: allowsDynamicID)
    }

    func globalType(of name: String) throws -> String {
        try self.queue.sync {
            self.context.exception = nil
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let result = self.context.evaluateScript("typeof globalThis['\(escaped)']")
            if let message = Self.exceptionMessage(self.context) {
                throw ProviderPluginError.script(message)
            }
            return result?.toString() ?? "undefined"
        }
    }

    // swiftlint:disable:next function_parameter_count
    func fetch(
        settings: [String: String],
        secrets: [String: String],
        now: Date,
        timeZone: TimeZone,
        contextOptions: ProviderPluginContextOptions,
        cookieResolver: ProviderPluginRuntime.CookieResolver?,
        instanceCookieResolver: ProviderPluginRuntime.InstanceCookieResolver?,
        completion: @escaping @Sendable (Result<ProviderPluginResult, Error>) -> Void)
    {
        self.queue.async {
            self.beginFetch(
                settings: settings,
                secrets: secrets,
                now: now,
                timeZone: timeZone,
                contextOptions: contextOptions,
                cookieResolver: cookieResolver,
                instanceCookieResolver: instanceCookieResolver,
                completion: completion)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func beginFetch(
        settings: [String: String],
        secrets: [String: String],
        now: Date,
        timeZone: TimeZone,
        contextOptions: ProviderPluginContextOptions,
        cookieResolver: ProviderPluginRuntime.CookieResolver?,
        instanceCookieResolver: ProviderPluginRuntime.InstanceCookieResolver?,
        completion: @escaping @Sendable (Result<ProviderPluginResult, Error>) -> Void)
    {
        self.context.exception = nil
        let redactionValues = ProviderPluginRedactionValues(secrets.values)
        let ctx = self.makeContext(
            settings: settings,
            secrets: secrets,
            now: now,
            timeZone: timeZone,
            contextOptions: contextOptions,
            cookieResolver: cookieResolver,
            instanceCookieResolver: instanceCookieResolver,
            redactionValues: redactionValues)
        guard self.context.exception == nil else {
            completion(.failure(ProviderPluginError.script(Self.exceptionMessage(self.context) ?? "ctx setup failed")))
            return
        }

        let callbackID = UUID()
        let resolve: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            defer { self.retainedCallbacks[callbackID] = nil }
            do {
                let snapshot = try ProviderPluginSnapshotMapper.mapResult(
                    JavaScriptCorePluginValue(value, keyEnumerator: self.keyEnumerator),
                    provider: self.manifest.id,
                    now: now,
                    allowsProviderExtensions: !self.enforcesUserResponsePolicy)
                completion(.success(snapshot))
            } catch {
                completion(.failure(ProviderPluginError
                        .invalidSnapshot(redactionValues.redact(error.localizedDescription))))
            }
        }
        let reject: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            defer { self.retainedCallbacks[callbackID] = nil }
            completion(.failure(self.failure(from: value, redactionValues: redactionValues)))
        }
        self.retainedCallbacks[callbackID] = [resolve, reject]

        guard let result = self.fetchUsage.call(withArguments: [ctx]) else {
            self.retainedCallbacks[callbackID] = nil
            completion(.failure(ProviderPluginError
                    .script(Self.exceptionMessage(self.context) ?? "fetchUsage returned no value")))
            return
        }
        if let message = Self.exceptionMessage(self.context) {
            self.retainedCallbacks[callbackID] = nil
            completion(.failure(ProviderPluginError.script(message)))
            return
        }

        guard let then = result.forProperty("then"), then.isObject else {
            resolve(result)
            return
        }
        _ = result.invokeMethod("then", withArguments: [resolve, reject])
        if let message = Self.exceptionMessage(self.context) {
            self.retainedCallbacks[callbackID] = nil
            completion(.failure(ProviderPluginError.script(message)))
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func makeContext(
        settings: [String: String],
        secrets: [String: String],
        now: Date,
        timeZone: TimeZone,
        contextOptions: ProviderPluginContextOptions,
        cookieResolver: ProviderPluginRuntime.CookieResolver?,
        instanceCookieResolver: ProviderPluginRuntime.InstanceCookieResolver?,
        redactionValues: ProviderPluginRedactionValues) -> JSValue
    {
        let ctx = JSValue(newObjectIn: self.context)!
        let host = JSValue(newObjectIn: self.context)!
        ctx.setObject(now.timeIntervalSince1970 * 1000, forKeyedSubscript: "__codexbarNowMillis" as NSString)
        if let optionalRequestTimeoutSeconds = contextOptions.optionalRequestTimeoutSeconds {
            ctx.setObject(
                optionalRequestTimeoutSeconds,
                forKeyedSubscript: "__codexbarOptionalRequestTimeoutSeconds" as NSString)
        }

        let settingGet: @convention(block) (String, Bool) -> JSValue = { [weak self] key, secure in
            guard let self else { return JSValue(undefinedIn: nil) }
            let expectedKind: ProviderPluginSetting.Kind = secure ? .secure : .plain
            guard self.manifest.settings.contains(where: { $0.key == key && $0.kind == expectedKind }) else {
                self.context.exception = JSValue(
                    newErrorFromMessage: "\(secure ? "secret" : "plain") setting '\(key)' is not declared",
                    in: self.context)
                return JSValue(undefinedIn: self.context)
            }
            let values = secure ? secrets : settings
            guard let value = values[key], !value.isEmpty else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: value, in: self.context)
        }
        host.setObject(settingGet, forKeyedSubscript: "settingGet" as NSString)

        let storage: @convention(block) (String, JSValue, JSValue) -> JSValue = { [weak self] operation, key, value in
            guard let self else { return JSValue(undefinedIn: nil) }
            do {
                guard let storage = contextOptions.storage,
                      !self.requestLock.withLock({ self.interrupted })
                else { throw ProviderPluginError.script("persistent storage is unavailable or not declared") }
                let result = try storage.access(
                    operation,
                    key: JavaScriptCorePluginValue(key, keyEnumerator: self.keyEnumerator),
                    value: JavaScriptCorePluginValue(value, keyEnumerator: self.keyEnumerator))
                return result.map { JSValue(object: $0, in: self.context) } ?? JSValue(nullIn: self.context)
            } catch {
                self.context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: self.context)
                return JSValue(undefinedIn: self.context)
            }
        }
        host.setObject(storage, forKeyedSubscript: "storage" as NSString)

        let env = JSValue(newObjectIn: self.context)!
        env.setObject(Self.normalizedTimeZoneIdentifier(timeZone), forKeyedSubscript: "timeZone" as NSString)
        ctx.setObject(env, forKeyedSubscript: "env" as NSString)
        let percentage: @convention(block) (Double, Double) -> Double = { used, limit in
            guard used.isFinite, limit.isFinite, limit > 0 else { return 100 }
            return min(100, max(0, used / limit * 100))
        }
        host.setObject(percentage, forKeyedSubscript: "pct" as NSString)
        let amountFromPercent: @convention(block) (Double, Double) -> Double = { percent, limit in
            percent / 100 * limit
        }
        host.setObject(amountFromPercent, forKeyedSubscript: "amountFromPercent" as NSString)
        let isDetailLabel: @convention(block) (String) -> Bool = { label in
            (try? ProviderDetailSection.Row(label: label, value: "—")) != nil
        }
        host.setObject(isDetailLabel, forKeyedSubscript: "isDetailLabel" as NSString)
        let currency: @convention(block) (Double, String) -> String = { amount, code in
            UsageFormatter.currencyString(amount, currencyCode: code)
        }
        host.setObject(currency, forKeyedSubscript: "formatCurrency" as NSString)

        let nextDailyReset: @convention(block) (String, Double) -> Double = { [weak self] identifier, rawHour in
            guard rawHour.isFinite,
                  rawHour.rounded() == rawHour,
                  (0...23).contains(rawHour),
                  let timeZone = TimeZone(identifier: identifier)
            else {
                self?.context.exception = JSValue(
                    newErrorFromMessage: "invalid daily reset time zone or hour",
                    in: self?.context)
                return .nan
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let start = calendar.startOfDay(for: now)
            var candidate = calendar.date(byAdding: .hour, value: Int(rawHour), to: start)!
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
            }
            return candidate.timeIntervalSince1970 * 1000
        }
        host.setObject(nextDailyReset, forKeyedSubscript: "nextDailyReset" as NSString)

        let http = self.makeHTTPBlock(
            settings: settings,
            secrets: secrets,
            redactionValues: redactionValues,
            contextOptions: contextOptions)
        host.setObject(http, forKeyedSubscript: "http" as NSString)

        let cookieAvailability: @convention(block) (String) -> String = { [weak self] rawDomain in
            guard let self else { return "off" }
            do {
                _ = try self.manifest.cookieDomain(rawDomain)
                return contextOptions.cookieSource.pluginAvailability(
                    hasResolver: contextOptions.cookieSessionResolver != nil
                        || (self.manifest.id.firstPartyProvider != nil && cookieResolver != nil)
                        || instanceCookieResolver != nil)
            } catch {
                self.context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: self.context)
                return "off"
            }
        }
        host.setObject(cookieAvailability, forKeyedSubscript: "cookieAvailability" as NSString)

        let rejectCookie: @convention(block) (String, String) -> Void = { [weak self] rawDomain, id in
            guard let self else { return }
            do {
                let domain = try self.manifest.cookieDomain(rawDomain)
                contextOptions.rejectCookie(domain: domain, id: id)
            } catch {
                self.context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: self.context)
            }
        }
        host.setObject(rejectCookie, forKeyedSubscript: "rejectCookie" as NSString)

        let cookieHeader = self.makeCookieBlock(
            source: contextOptions.cookieSource,
            resolver: cookieResolver,
            instanceResolver: instanceCookieResolver,
            redactionValues: redactionValues)
        host.setObject(cookieHeader, forKeyedSubscript: "cookieHeader" as NSString)
        let cookieSession = self.makeCookieBlock(
            source: contextOptions.cookieSource,
            resolver: nil,
            instanceResolver: nil,
            sessionResolver: contextOptions.cookieSessionResolver,
            redactionValues: redactionValues)
        host.setObject(cookieSession, forKeyedSubscript: "cookieSession" as NSString)

        let cacheGet: @convention(block) (String) -> JSValue = { [weak self] key in
            guard let self else { return JSValue(undefinedIn: nil) }
            guard let entry = self.cache[key], entry.expiresAt > Date() else {
                self.cache[key] = nil
                return JSValue(undefinedIn: self.context)
            }
            return entry.value
        }
        let cacheSet: @convention(block) (String, JSValue, Double) -> Void = { [weak self] key, value, ttl in
            guard let self, ttl.isFinite, ttl > 0 else { return }
            self.cache[key] = (value, Date().addingTimeInterval(min(ttl, 86400)))
        }
        host.setObject(cacheGet, forKeyedSubscript: "cacheGet" as NSString)
        host.setObject(cacheSet, forKeyedSubscript: "cacheSet" as NSString)

        let log: @convention(block) (String) -> Void = { [manifest] message in
            let logger = CodexBarLog.logger(LogCategories.providerInstance(manifest.id, scope: "plugin"))
            logger.debug("\(redactionValues.redact(message))")
        }
        host.setObject(log, forKeyedSubscript: "log" as NSString)

        _ = self.applyPrelude.call(withArguments: [ctx, host])
        return ctx
    }

    func requestInterrupt() {
        let tasks = self.requestLock.withLock {
            self.interrupted = true
            return Array(self.requests.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    private static func normalizedTimeZoneIdentifier(_ timeZone: TimeZone) -> String {
        if timeZone.secondsFromGMT() == 0,
           ["GMT", "Etc/GMT", "Etc/UTC", "UTC"].contains(timeZone.identifier)
        {
            return "UTC"
        }
        return timeZone.identifier
    }

    private func makeHTTPBlock(
        settings: [String: String],
        secrets: [String: String],
        redactionValues: ProviderPluginRedactionValues,
        contextOptions: ProviderPluginContextOptions) -> HTTPBlock
    {
        { [weak self] rawURL, options, method, wantsJSON, resolve, reject in
            self?.startHTTPRequest(
                rawURL: rawURL,
                options: options,
                method: method,
                settings: settings,
                secrets: secrets,
                redactionValues: redactionValues,
                contextOptions: contextOptions,
                callbacks: ProviderPluginHTTPRequestCallbacks(
                    wantsJSON: wantsJSON,
                    resolve: ProviderPluginJSValueBox(resolve),
                    reject: ProviderPluginJSValueBox(reject)))
        }
    }

    // Keep the JavaScript bridge inputs explicit at the executor boundary.
    // swiftlint:disable:next function_parameter_count
    private func startHTTPRequest(
        rawURL: String,
        options: JSValue,
        method: String,
        settings: [String: String],
        secrets: [String: String],
        redactionValues: ProviderPluginRedactionValues,
        contextOptions: ProviderPluginContextOptions,
        callbacks: ProviderPluginHTTPRequestCallbacks)
    {
        let request: ProviderPluginHTTPResponse.Request
        do {
            guard let dictionary = options.toDictionary() as? [String: Any] else {
                throw ProviderPluginError.http("request options must be an object")
            }
            request = try ProviderPluginHTTPResponse.Request(
                rawURL: rawURL,
                options: dictionary,
                method: method,
                settings: settings,
                secrets: secrets,
                manifest: self.manifest,
                enforcesUserResponsePolicy: self.enforcesUserResponsePolicy)
        } catch {
            self.reject(callbacks.reject, error: error, transportErrors: redactionValues.transportErrors)
            return
        }

        let worker = self
        let requestID = UUID()
        self.requestLock.lock()
        guard !self.interrupted else {
            self.requestLock.unlock()
            self.reject(callbacks.reject, error: CancellationError(), transportErrors: redactionValues.transportErrors)
            return
        }
        defer { self.requestLock.unlock() }
        self.requests[requestID] = Task.detached {
            defer { _ = worker.requestLock.withLock { worker.requests.removeValue(forKey: requestID) } }
            do {
                let payload = try await ProviderPluginHTTPResponse.fetch(
                    request,
                    transport: worker.transport,
                    wantsJSON: callbacks.wantsJSON,
                    responseSizeLimit: worker.responseSizeLimit,
                    enforcesUserResponsePolicy: worker.enforcesUserResponsePolicy,
                    rejectsNonSuccessResponses: worker.rejectsNonSuccessResponses,
                    contextOptions: contextOptions)
                worker.queue.async {
                    let value = JSValue(object: payload.value, in: worker.context) ?? JSValue(nullIn: worker.context)
                    _ = callbacks.resolve.value.call(withArguments: [value as Any])
                }
            } catch {
                let message = redactionValues.redact(error.localizedDescription)
                worker.queue.async {
                    worker.reject(
                        callbacks.reject,
                        error: error,
                        message: message,
                        transportErrors: redactionValues.transportErrors)
                }
            }
        }
    }

    private func makeCookieBlock(
        source: ProviderCookieSource,
        resolver: ProviderPluginRuntime.CookieResolver?,
        instanceResolver: ProviderPluginRuntime.InstanceCookieResolver?,
        sessionResolver: ProviderPluginRuntime.CookieSessionResolver? = nil,
        redactionValues: ProviderPluginRedactionValues) -> CookieBlock
    {
        { [weak self] rawDomain, cachedOnly, resolve, reject in
            guard let self else { return }
            guard let domain = try? self.manifest.cookieDomain(rawDomain)
            else {
                self.reject(
                    ProviderPluginJSValueBox(reject),
                    error: ProviderPluginError.secretAccess("cookie domain is not declared"))
                return
            }
            guard source != .off else {
                self.reject(
                    ProviderPluginJSValueBox(reject),
                    error: ProviderPluginError.secretAccess("browser cookies are disabled for this provider"))
                return
            }
            let resolveCookie: @Sendable () async throws -> (header: String, payload: String)
            if let sessionResolver {
                resolveCookie = {
                    guard let session = try await sessionResolver(domain, cachedOnly) else { return ("", "null") }
                    guard session.origin == "https://\(domain)" else {
                        throw ProviderPluginError.secretAccess("cookie session origin does not match its domain")
                    }
                    return try (session.header, session.json())
                }
            } else if let provider = self.manifest.id.firstPartyProvider, let resolver {
                resolveCookie = { let header = try await resolver(provider, domain); return (header, header) }
            } else if let instanceResolver {
                resolveCookie = {
                    let header = try await instanceResolver(self.manifest.id, domain)
                    return (header, header)
                }
            } else {
                self.reject(
                    ProviderPluginJSValueBox(reject),
                    error: ProviderPluginError.secretAccess("browser cookie access is unavailable"))
                return
            }
            let worker = self
            let resolveBox = ProviderPluginJSValueBox(resolve)
            let rejectBox = ProviderPluginJSValueBox(reject)
            Task.detached {
                do {
                    let (header, payload) = try await resolveCookie()
                    redactionValues.insert(header)
                    for pair in CookieHeaderNormalizer.pairs(from: header) {
                        redactionValues.insert(pair.value)
                    }
                    worker.queue.async {
                        _ = resolveBox.value.call(withArguments: [payload])
                    }
                } catch {
                    let failure = ProviderPluginError.secretAccess(redactionValues.redact(error.localizedDescription))
                    worker.queue.async {
                        worker.reject(rejectBox, error: failure)
                    }
                }
            }
        }
    }

    private func reject(
        _ reject: ProviderPluginJSValueBox,
        error: Error,
        message: String? = nil,
        transportErrors: ProviderPluginHTTPResponse.TransportErrors? = nil)
    {
        let payload = ProviderPluginHTTPResponse.failure(
            error,
            message: message ?? error.localizedDescription,
            transportErrors: transportErrors)
        let value = JSValue(newErrorFromMessage: payload["message"] as? String, in: self.context)
        for (key, field) in payload {
            value?.setObject(field, forKeyedSubscript: key as NSString)
        }
        _ = reject.value.call(withArguments: [value as Any])
    }

    private func message(from value: JSValue) -> String {
        if value.isObject,
           let message = value.forProperty("message"),
           message.isString
        {
            return message.toString()
        }
        return value.toString()
    }

    private func failure(
        from value: JSValue,
        redactionValues: ProviderPluginRedactionValues) -> Error
    {
        if let error = redactionValues.transportErrors.error(for: JavaScriptCorePluginValue(
            value,
            keyEnumerator: self.keyEnumerator)) { return error }
        let message = redactionValues.redact(self.message(from: value))
        if let classified = ProviderPluginClassifiedFailureParser.error(from: message) {
            return classified
        }
        return ProviderPluginError.script(message)
    }

    private static func exceptionMessage(_ context: JSContext) -> String? {
        defer { context.exception = nil }
        guard let exception = context.exception else { return nil }
        if let message = exception.forProperty("message"), message.isString {
            return message.toString()
        }
        return exception.toString()
    }
}
#endif
