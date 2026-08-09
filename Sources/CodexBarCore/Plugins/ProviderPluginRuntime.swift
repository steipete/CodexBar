import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore
#endif

public final class ProviderPluginRuntime: @unchecked Sendable {
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
    private let rejectsNonSuccessResponses: Bool
    private let allowsDynamicID: Bool
    private let contextOptions: ProviderPluginContextOptions
    private let engineKind: ProviderPluginEngineKind
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
        rejectsNonSuccessResponses: Bool = false,
        allowsDynamicID: Bool = false,
        engine: ProviderPluginEngineKind = .automatic) throws
    {
        try self.init(
            source: source,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: transport,
            timeout: timeout,
            responseSizeLimit: responseSizeLimit,
            rejectsNonSuccessResponses: rejectsNonSuccessResponses,
            allowsDynamicID: allowsDynamicID,
            contextOptions: .production,
            engine: engine)
    }

    init(
        source: String,
        resourceBundle: Bundle?,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        responseSizeLimit: Int = ProviderPluginRuntime.maximumResponseBytes,
        rejectsNonSuccessResponses: Bool = false,
        allowsDynamicID: Bool = false,
        contextOptions: ProviderPluginContextOptions = .production,
        engine: ProviderPluginEngineKind = .automatic) throws
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
        self.rejectsNonSuccessResponses = rejectsNonSuccessResponses
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
            rejectsNonSuccessResponses: rejectsNonSuccessResponses,
            allowsDynamicID: allowsDynamicID)
        self.worker = worker
        self.manifest = worker.manifest
    }

    public func fetchUsage(
        settings: [String: String] = [:],
        secrets: [String: String] = [:],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        cookieResolver: CookieResolver? = nil,
        instanceCookieResolver: InstanceCookieResolver? = nil) async throws -> UsageSnapshot
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

        let worker = try self.currentWorker()
        let gate = ProviderPluginCompletionGate<UsageSnapshot>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            worker.fetch(
                settings: sanitizedSettings,
                secrets: sanitizedSecrets,
                now: now,
                timeZone: timeZone,
                contextOptions: self.contextOptions,
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
            rejectsNonSuccessResponses: self.rejectsNonSuccessResponses,
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

private final class ProviderPluginObjectBox: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

private struct ProviderPluginHTTPRequestCallbacks: @unchecked Sendable {
    let wantsJSON: Bool
    let resolve: ProviderPluginJSValueBox
    let reject: ProviderPluginJSValueBox
}

private final class ProviderPluginRedactionValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String>

    init(_ values: some Sequence<String>) {
        self.values = Set(values.filter { !$0.isEmpty })
    }

    func insert(_ value: String) {
        guard !value.isEmpty else { return }
        _ = self.lock.withLock { self.values.insert(value) }
    }

    func redact(_ message: String) -> String {
        self.lock.withLock {
            self.values.reduce(message) { partial, value in
                partial.replacingOccurrences(of: value, with: "<redacted>")
            }
        }
    }
}

final class JavaScriptCoreProviderPluginEngine: ProviderPluginEngine, @unchecked Sendable {
    private typealias HTTPBlock = @convention(block) (String, JSValue, String, Bool, JSValue, JSValue) -> Void
    private typealias CookieBlock = @convention(block) (String, JSValue, JSValue) -> Void

    let manifest: ProviderPluginManifest

    private let queue: DispatchQueue
    private let context: JSContext
    private let applyPrelude: JSValue
    private let fetchUsage: JSValue
    private let transport: any ProviderHTTPTransport
    private let responseSizeLimit: Int
    private let rejectsNonSuccessResponses: Bool
    private var cache: [String: (value: JSValue, expiresAt: Date)] = [:]
    private var retainedCallbacks: [UUID: [Any]] = [:]

    // swiftlint:disable:next function_parameter_count
    static func make(
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        responseSizeLimit: Int,
        rejectsNonSuccessResponses: Bool,
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
                rejectsNonSuccessResponses: rejectsNonSuccessResponses,
                allowsDynamicID: allowsDynamicID)
        }
    }

    private init(
        queue: DispatchQueue,
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        responseSizeLimit: Int,
        rejectsNonSuccessResponses: Bool,
        allowsDynamicID: Bool) throws
    {
        guard let context = JSContext() else {
            throw ProviderPluginError.load("JavaScriptCore could not create a context")
        }
        self.queue = queue
        self.context = context
        self.transport = transport
        self.responseSizeLimit = responseSizeLimit
        self.rejectsNonSuccessResponses = rejectsNonSuccessResponses

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
            definition: JavaScriptCorePluginValue(definition),
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
        completion: @escaping @Sendable (Result<UsageSnapshot, Error>) -> Void)
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
        completion: @escaping @Sendable (Result<UsageSnapshot, Error>) -> Void)
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
                let snapshot = try ProviderPluginSnapshotMapper.map(
                    JavaScriptCorePluginValue(value),
                    provider: self.manifest.id,
                    now: now)
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
            let now = Date()
            let start = calendar.startOfDay(for: now)
            var candidate = calendar.date(byAdding: .hour, value: Int(rawHour), to: start)!
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
            }
            return candidate.timeIntervalSince1970 * 1000
        }
        host.setObject(nextDailyReset, forKeyedSubscript: "nextDailyReset" as NSString)

        let http = self.makeHTTPBlock(settings: settings, secrets: secrets, redactionValues: redactionValues)
        host.setObject(http, forKeyedSubscript: "http" as NSString)

        let cookieHeader = self.makeCookieBlock(
            resolver: cookieResolver,
            instanceResolver: instanceCookieResolver,
            redactionValues: redactionValues)
        host.setObject(cookieHeader, forKeyedSubscript: "cookieHeader" as NSString)

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

    func requestInterrupt() {}

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
        redactionValues: ProviderPluginRedactionValues) -> HTTPBlock
    {
        { [weak self] rawURL, options, method, wantsJSON, resolve, reject in
            self?.startHTTPRequest(
                rawURL: rawURL,
                options: options,
                method: method,
                settings: settings,
                secrets: secrets,
                redactionValues: redactionValues,
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
        callbacks: ProviderPluginHTTPRequestCallbacks)
    {
        let request: URLRequest
        do {
            request = try self.makeRequest(
                rawURL: rawURL,
                options: options,
                method: method,
                settings: settings,
                secrets: secrets)
        } catch {
            self.reject(callbacks.reject, error: error)
            return
        }

        let worker = self
        let transport = self.transport
        let responseSizeLimit = self.responseSizeLimit
        Task.detached {
            do {
                let responseTask = Task { try await transport.response(for: request) }
                let response: ProviderHTTPResponse = switch await BoundedTaskJoin(sourceTask: responseTask)
                    .value(joinGrace: .seconds(request.timeoutInterval))
                {
                case let .value(response): response
                case let .failure(error): throw error
                case .timedOut: throw URLError(.timedOut)
                }
                guard response.data.count <= responseSizeLimit else {
                    throw ProviderPluginError.http("response exceeded the \(responseSizeLimit)-byte limit")
                }
                if worker.rejectsNonSuccessResponses, !(200..<300).contains(response.statusCode) {
                    throw ProviderPluginError.http("request returned HTTP \(response.statusCode)")
                }
                if worker.rejectsNonSuccessResponses,
                   let encoding = response.response.value(forHTTPHeaderField: "Content-Encoding"),
                   !encoding.isEmpty,
                   encoding.caseInsensitiveCompare("identity") != .orderedSame
                {
                    throw ProviderPluginError.http("compressed responses are not allowed")
                }
                let payload = try ProviderPluginObjectBox(Self.responsePayload(
                    response,
                    wantsJSON: callbacks.wantsJSON))
                worker.queue.async {
                    let value = JSValue(object: payload.value, in: worker.context) ?? JSValue(nullIn: worker.context)
                    _ = callbacks.resolve.value.call(withArguments: [value as Any])
                }
            } catch {
                let failure = ProviderPluginError.http(redactionValues.redact(error.localizedDescription))
                worker.queue.async {
                    worker.reject(callbacks.reject, error: failure)
                }
            }
        }
    }

    private func makeCookieBlock(
        resolver: ProviderPluginRuntime.CookieResolver?,
        instanceResolver: ProviderPluginRuntime.InstanceCookieResolver?,
        redactionValues: ProviderPluginRedactionValues) -> CookieBlock
    {
        { [weak self] rawDomain, resolve, reject in
            guard let self else { return }
            let domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard self.manifest.capabilities.contains(.browserCookies),
                  self.manifest.cookieDomains.contains(domain)
            else {
                self.reject(
                    ProviderPluginJSValueBox(reject),
                    error: ProviderPluginError.secretAccess("cookie domain is not declared"))
                return
            }
            let resolveCookie: @Sendable () async throws -> String
            if let provider = self.manifest.id.firstPartyProvider, let resolver {
                resolveCookie = { try await resolver(provider, domain) }
            } else if let instanceResolver {
                resolveCookie = { try await instanceResolver(self.manifest.id, domain) }
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
                    let header = try await resolveCookie()
                    redactionValues.insert(header)
                    for pair in CookieHeaderNormalizer.pairs(from: header) {
                        redactionValues.insert(pair.value)
                    }
                    worker.queue.async {
                        _ = resolveBox.value.call(withArguments: [header])
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

    private func makeRequest(
        rawURL: String,
        options: JSValue,
        method: String,
        settings: [String: String],
        secrets: [String: String]) throws -> URLRequest
    {
        guard let url = URL(string: rawURL) else {
            throw ProviderPluginError.networkPolicy("request URL is invalid")
        }
        guard try self.allowedOrigin(for: url, settings: settings) else {
            let rejectedOrigin = (try? ProviderPluginOrigin.normalizedOrigin(
                of: url,
                policy: url.scheme?.lowercased() == "http" ? .httpsOrLoopbackHTTP : .https)) ?? "invalid"
            throw ProviderPluginError.networkPolicy("origin '\(rejectedOrigin)' is not declared")
        }

        var request = URLRequest(url: url)
        guard method == "GET" || method == "POST" else {
            throw ProviderPluginError.networkPolicy("HTTP method is not allowed")
        }
        request.httpMethod = method
        request.timeoutInterval = try Self.timeoutSeconds(options)
        if method == "POST" {
            guard let bodyJSON = options.forProperty("bodyJSON"), bodyJSON.isString else {
                throw ProviderPluginError.http("POST JSON body is missing")
            }
            request.httpBody = Data(bodyJSON.toString().utf8)
        }
        if options.isObject,
           let headers = options.forProperty("headers"),
           headers.isObject,
           let dictionary = headers.toDictionary() as? [String: Any]
        {
            for (name, rawValue) in dictionary {
                guard let value = rawValue as? String else {
                    throw ProviderPluginError.http("request header '\(name)' must be a string")
                }
                if let auth = self.manifest.auth,
                   name.caseInsensitiveCompare(auth.header) == .orderedSame
                {
                    throw ProviderPluginError.networkPolicy("plugins may not override the auth header")
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        // The broker owns representation headers so plugins cannot relax the user-plugin response boundary.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if self.rejectsNonSuccessResponses {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let auth = self.manifest.auth {
            guard let secret = secrets[auth.secret], !secret.isEmpty else {
                throw ProviderPluginError.secretAccess("required auth secret is unavailable")
            }
            let authValue = switch auth.type {
            case .bearer:
                "Bearer \(secret)"
            case .authorizationScheme:
                "\(auth.scheme!) \(secret)"
            case .xAPIKey, .header:
                secret
            }
            request.setValue(authValue, forHTTPHeaderField: auth.header)
        }
        return request
    }

    private static func timeoutSeconds(_ options: JSValue) throws -> TimeInterval {
        guard options.isObject,
              let value = options.forProperty("timeoutSeconds"),
              !value.isUndefined,
              !value.isNull
        else { return 15 }
        guard value.isNumber else {
            throw ProviderPluginError.http("timeoutSeconds must be a number from 1 through 30")
        }
        let seconds = value.toDouble()
        guard seconds.isFinite, (1...30).contains(seconds) else {
            throw ProviderPluginError.http("timeoutSeconds must be a number from 1 through 30")
        }
        return seconds
    }

    private func allowedOrigin(for url: URL, settings: [String: String]) throws -> Bool {
        for endpoint in self.manifest.endpoints {
            switch endpoint {
            case let .fixed(declared):
                if (try? ProviderPluginOrigin.normalizedOrigin(of: url)) == declared {
                    return true
                }
            case let .setting(key, policy):
                guard let rawValue = settings[key], !rawValue.isEmpty,
                      let configuredURL = URL(string: rawValue), configuredURL.fragment == nil
                else { continue }
                let configuredOrigin = try ProviderPluginOrigin.normalizedOrigin(of: configuredURL, policy: policy)
                if try ProviderPluginOrigin
                    .normalizedOrigin(of: url, policy: policy) == configuredOrigin
                {
                    return true
                }
            }
        }
        return false
    }

    private static func responsePayload(_ response: ProviderHTTPResponse, wantsJSON: Bool) throws -> [String: Any] {
        var headers: [String: String] = [:]
        for (key, value) in response.response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var payload: [String: Any] = [
            "status": response.statusCode,
            "headers": headers,
        ]
        if wantsJSON {
            do {
                payload["json"] = try JSONSerialization.jsonObject(with: response.data)
            } catch {
                throw ProviderPluginError.http("response was not valid JSON")
            }
        } else {
            guard let text = String(data: response.data, encoding: .utf8) else {
                throw ProviderPluginError.http("response body was not valid UTF-8")
            }
            payload["bodyText"] = text
        }
        return payload
    }

    private func reject(_ reject: ProviderPluginJSValueBox, error: Error) {
        let value = JSValue(newErrorFromMessage: error.localizedDescription, in: self.context)
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
