import CoreFoundation
import CQuickJS
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum QuickJSHostFunction: Int32 {
    case defineProvider
    case settingGet
    case http
    case cookieHeader
    case cacheGet
    case cacheSet
    case log
    case nextDailyReset
    case pct
    case amountFromPercent
}

enum QuickJSRuntimeLimits {
    /// The dedicated worker thread's native stack. Sized far above the JavaScript budget so even a deep
    /// Swift async/test baseline at the point JavaScript begins still leaves several MiB of physical stack.
    static let nativeStackSizeBytes = 8 * 1024 * 1024

    /// The JavaScript stack budget must sit well below the native stack it runs on, or QuickJS's overflow
    /// guard fires with too little native headroom left to *construct* the RangeError and the throw path
    /// itself faults (a hard crash observed only on CI runners with deep baseline frames; the guard is
    /// unreliable at thin margins — quickjs-ng/zipline#1130 class). Deriving the JS limit as a quarter of
    /// the actual worker stack makes the invariant hold for any stack size, including deliberately small
    /// ones, so a misconfigured or starved thread throws cleanly instead of crashing.
    static func javaScriptStackLimitBytes(workerStackSizeBytes: Int) -> Int {
        max(64 * 1024, workerStackSizeBytes / 4)
    }
}

private func quickJSHostCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ context: OpaquePointer?,
    _ magic: Int32,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<JSValue>?) -> JSValue
{
    guard let opaque, let context, let function = QuickJSHostFunction(rawValue: magic) else {
        return cqjs_undefined()
    }
    let engine = Unmanaged<QuickJSProviderPluginEngine>.fromOpaque(opaque).takeUnretainedValue()
    return engine.handleHostCall(function, context: context, arguments: argv, count: Int(argc))
}

private func quickJSInstallContextOptions(
    _ options: ProviderPluginContextOptions,
    context: OpaquePointer,
    target: JSValue)
{
    guard let timeout = options.optionalRequestTimeoutSeconds else { return }
    _ = JS_SetPropertyStr(
        context,
        target,
        "__codexbarOptionalRequestTimeoutSeconds",
        JS_NewFloat64(context, timeout))
}

private func quickJSNormalizedTimeZoneIdentifier(_ timeZone: TimeZone) -> String {
    if timeZone.secondsFromGMT() == 0,
       ["GMT", "Etc/GMT", "Etc/UTC", "UTC"].contains(timeZone.identifier)
    {
        return "UTC"
    }
    return timeZone.identifier
}

private final class QuickJSPluginValue: ProviderPluginValue {
    private unowned let engine: QuickJSProviderPluginEngine
    private let value: JSValue

    init(engine: QuickJSProviderPluginEngine, value: JSValue) {
        self.engine = engine
        self.value = value
    }

    deinit {
        cqjs_free_value(self.engine.context, self.value)
    }

    var isObject: Bool {
        cqjs_is_object(self.value)
    }

    var isArray: Bool {
        JS_IsArray(self.value)
    }

    var isNull: Bool {
        cqjs_is_null(self.value)
    }

    var isUndefined: Bool {
        cqjs_is_undefined(self.value)
    }

    var isString: Bool {
        cqjs_is_string(self.value)
    }

    var isNumber: Bool {
        cqjs_is_number(self.value)
    }

    var isDate: Bool {
        JS_IsDate(self.value)
    }

    func property(_ name: String) -> (any ProviderPluginValue)? {
        QuickJSPluginValue(engine: self.engine, value: JS_GetPropertyStr(self.engine.context, self.value, name))
    }

    func element(at index: Int) -> (any ProviderPluginValue)? {
        QuickJSPluginValue(
            engine: self.engine,
            value: JS_GetPropertyUint32(self.engine.context, self.value, UInt32(index)))
    }

    func stringValue() -> String {
        (try? self.engine.string(from: self.value)) ?? ""
    }

    func int32Value() -> Int32 {
        var value: Int32 = 0
        _ = JS_ToInt32(self.engine.context, &value, self.value)
        return value
    }

    func doubleValue() -> Double {
        var value = Double.nan
        _ = JS_ToFloat64(self.engine.context, &value, self.value)
        return value
    }

    func dateValue() -> Date? {
        guard self.isDate else { return nil }
        let getTime = JS_GetPropertyStr(self.engine.context, self.value, "getTime")
        defer { cqjs_free_value(self.engine.context, getTime) }
        let result = JS_Call(self.engine.context, getTime, self.value, 0, nil)
        defer { cqjs_free_value(self.engine.context, result) }
        var milliseconds = 0.0
        guard !cqjs_is_exception(result), JS_ToFloat64(self.engine.context, &milliseconds, result) == 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

final class QuickJSProviderPluginEngine: ProviderPluginEngine, @unchecked Sendable {
    static let memoryLimitBytes = 64 * 1024 * 1024

    static func transpileTypeScript(source: String, sucraseSource: String) throws -> String {
        try QuickJSTypeScriptTranspiler.transpile(source: source, sucraseSource: sucraseSource)
    }

    private struct FetchState {
        let settings: [String: String]
        let secrets: [String: String]
        let cookieResolver: ProviderPluginRuntime.CookieResolver?
        let instanceCookieResolver: ProviderPluginRuntime.InstanceCookieResolver?
        let redactionValues: QuickJSRedactionValues
        let deadline: Date
    }

    private struct CacheEntry {
        let json: String
        let expiresAt: Date
    }

    // @unchecked Sendable is safe because every mutable engine field and QuickJS API call is confined
    // to this serial worker. requestInterrupt() is the watchdog's explicitly thread-safe escape hatch.
    private let worker: QuickJSSerialWorker
    private let runtime: OpaquePointer
    fileprivate let context: OpaquePointer
    private let transport: any ProviderHTTPTransport
    private let timeout: TimeInterval
    private let responseSizeLimit: Int
    private let enforcesUserResponsePolicy: Bool
    private var watchdog: OpaquePointer?
    private var definition: JSValue?
    private var applyPrelude: JSValue?
    private var fetchUsage: JSValue?
    private var loadedManifest: ProviderPluginManifest?
    private var fetchState: FetchState?
    private var cache: [String: CacheEntry] = [:]

    var manifest: ProviderPluginManifest {
        guard let loadedManifest = self.loadedManifest else {
            preconditionFailure("QuickJS plugin manifest accessed before initialization")
        }
        return loadedManifest
    }

    private var rejectsNonSuccessResponses: Bool {
        self.enforcesUserResponsePolicy && !self.manifest.capabilities.contains(.httpStatus)
    }

    // swiftlint:disable:next function_parameter_count
    static func make(
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        timeout: TimeInterval,
        responseSizeLimit: Int,
        enforcesUserResponsePolicy: Bool,
        allowsDynamicID: Bool,
        workerStackSizeBytes: Int = QuickJSRuntimeLimits.nativeStackSizeBytes) throws -> QuickJSProviderPluginEngine
    {
        let worker = QuickJSSerialWorker(
            name: "CodexBar QuickJS provider plugin",
            stackSizeBytes: workerStackSizeBytes)
        return try worker.sync {
            guard let runtime = JS_NewRuntime() else {
                throw ProviderPluginError.load("QuickJS could not create a runtime")
            }
            JS_SetMemoryLimit(runtime, Self.memoryLimitBytes)
            JS_SetMaxStackSize(
                runtime,
                QuickJSRuntimeLimits.javaScriptStackLimitBytes(workerStackSizeBytes: workerStackSizeBytes))
            guard let context = JS_NewContext(runtime) else {
                JS_FreeRuntime(runtime)
                throw ProviderPluginError.load("QuickJS could not create a context")
            }
            let engine = QuickJSProviderPluginEngine(
                worker: worker,
                runtime: runtime,
                context: context,
                transport: transport,
                timeout: timeout,
                responseSizeLimit: responseSizeLimit,
                enforcesUserResponsePolicy: enforcesUserResponsePolicy)
            try engine.load(source: source, preludeSource: preludeSource, allowsDynamicID: allowsDynamicID)
            return engine
        }
    }

    private init(
        worker: QuickJSSerialWorker,
        runtime: OpaquePointer,
        context: OpaquePointer,
        transport: any ProviderHTTPTransport,
        timeout: TimeInterval,
        responseSizeLimit: Int,
        enforcesUserResponsePolicy: Bool)
    {
        self.worker = worker
        self.runtime = runtime
        self.context = context
        self.transport = transport
        self.timeout = timeout
        self.responseSizeLimit = responseSizeLimit
        self.enforcesUserResponsePolicy = enforcesUserResponsePolicy
    }

    deinit {
        let runtime = self.runtime
        let context = self.context
        let definition = self.definition
        let applyPrelude = self.applyPrelude
        let fetchUsage = self.fetchUsage
        let watchdog = self.watchdog
        let teardown = {
            if let definition {
                cqjs_free_value(context, definition)
            }
            if let applyPrelude {
                cqjs_free_value(context, applyPrelude)
            }
            if let fetchUsage {
                cqjs_free_value(context, fetchUsage)
            }
            if let watchdog {
                cqjs_watchdog_disarm(watchdog)
            }
            // The runtime retains the interrupt-handler opaque pointer until it is freed.
            JS_FreeContext(context)
            JS_FreeRuntime(runtime)
            if let watchdog {
                cqjs_watchdog_destroy(watchdog)
            }
        }
        if self.worker.isCurrentThread {
            teardown()
        } else {
            try? self.worker.sync(teardown)
        }
        self.worker.shutdown()
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
        self.worker.async {
            completion(Result {
                try self.fetchOnWorker(
                    settings: settings,
                    secrets: secrets,
                    now: now,
                    timeZone: timeZone,
                    contextOptions: contextOptions,
                    cookieResolver: cookieResolver,
                    instanceCookieResolver: instanceCookieResolver)
            })
        }
    }

    func globalType(of name: String) throws -> String {
        try self.worker.sync {
            JS_UpdateStackTop(self.runtime)
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let result = try self.evaluate("typeof globalThis['\(escaped)']", filename: "<global-type>")
            defer { cqjs_free_value(self.context, result) }
            return try self.string(from: result)
        }
    }

    func requestInterrupt() {
        if let watchdog = self.watchdog {
            cqjs_watchdog_interrupt(watchdog)
        }
    }

    private func load(source: String, preludeSource: String, allowsDynamicID: Bool) throws {
        JS_UpdateStackTop(self.runtime)
        guard let watchdog = cqjs_watchdog_create(
            quickJSHostCallback,
            Unmanaged.passUnretained(self).toOpaque())
        else {
            throw ProviderPluginError.load("QuickJS could not create its watchdog")
        }
        self.watchdog = watchdog
        cqjs_watchdog_install(watchdog, self.runtime, self.context)
        cqjs_watchdog_arm(watchdog, UInt64(self.timeout * 1000))
        defer { cqjs_watchdog_disarm(watchdog) }

        let global = JS_GetGlobalObject(self.context)
        defer { cqjs_free_value(self.context, global) }
        let defineProvider = cqjs_new_host_function(
            self.context,
            QuickJSHostFunction.defineProvider.rawValue,
            "defineProvider",
            1)
        _ = JS_SetPropertyStr(self.context, global, "defineProvider", defineProvider)

        self.applyPrelude = try self.evaluate(preludeSource, filename: "provider-plugin-prelude.js")
        let sourceResult = try self.evaluate(source, filename: "provider-plugin.js")
        cqjs_free_value(self.context, sourceResult)
        guard let definition = self.definition else {
            throw ProviderPluginError.invalidManifest("plugin did not call defineProvider(...)")
        }
        let fetchUsage = JS_GetPropertyStr(self.context, definition, "fetchUsage")
        guard JS_IsFunction(self.context, fetchUsage) else {
            cqjs_free_value(self.context, fetchUsage)
            throw ProviderPluginError.invalidManifest("'fetchUsage' must be a function")
        }
        self.fetchUsage = fetchUsage
        let json = try self.jsonObject(from: definition)
        self.loadedManifest = try ProviderPluginManifest(
            definition: JSONProviderPluginValue(json),
            allowsDynamicID: allowsDynamicID)
    }

    // swiftlint:disable:next function_parameter_count
    private func fetchOnWorker(
        settings: [String: String],
        secrets: [String: String],
        now: Date,
        timeZone: TimeZone,
        contextOptions: ProviderPluginContextOptions,
        cookieResolver: ProviderPluginRuntime.CookieResolver?,
        instanceCookieResolver: ProviderPluginRuntime.InstanceCookieResolver?) throws -> UsageSnapshot
    {
        JS_UpdateStackTop(self.runtime)
        guard let applyPrelude = self.applyPrelude, let fetchUsage = self.fetchUsage,
              let watchdog = self.watchdog
        else {
            throw ProviderPluginError.load("QuickJS plugin is not initialized")
        }
        let redactionValues = QuickJSRedactionValues(secrets.values)
        self.fetchState = FetchState(
            settings: settings,
            secrets: secrets,
            cookieResolver: cookieResolver,
            instanceCookieResolver: instanceCookieResolver,
            redactionValues: redactionValues,
            deadline: Date().addingTimeInterval(self.timeout))
        defer { self.fetchState = nil }
        cqjs_watchdog_arm(watchdog, UInt64(self.timeout * 1000))
        defer { cqjs_watchdog_disarm(watchdog) }

        let ctx = JS_NewObject(self.context)
        let host = JS_NewObject(self.context)
        defer {
            cqjs_free_value(self.context, host)
            cqjs_free_value(self.context, ctx)
        }
        try self.installHostFunctions(on: host)
        _ = JS_SetPropertyStr(
            self.context,
            ctx,
            "__codexbarNowMillis",
            JS_NewFloat64(self.context, now.timeIntervalSince1970 * 1000))
        quickJSInstallContextOptions(contextOptions, context: self.context, target: ctx)
        let env = JS_NewObject(self.context)
        _ = JS_SetPropertyStr(
            self.context,
            env,
            "timeZone",
            self.makeString(quickJSNormalizedTimeZoneIdentifier(timeZone)))
        _ = JS_SetPropertyStr(self.context, ctx, "env", env)

        let preparedContext = try self.call(applyPrelude, arguments: [ctx, host])
        cqjs_free_value(self.context, preparedContext)
        var result = try self.call(fetchUsage, arguments: [ctx])
        if JS_IsPromise(result) {
            while JS_PromiseState(self.context, result) == JS_PROMISE_PENDING {
                var pendingContext: OpaquePointer?
                JS_UpdateStackTop(self.runtime)
                let executed = JS_ExecutePendingJob(self.runtime, &pendingContext)
                if executed < 0 {
                    cqjs_free_value(self.context, result)
                    throw self.scriptErrorFromException()
                }
                if executed == 0 {
                    cqjs_free_value(self.context, result)
                    throw ProviderPluginError.script("promise did not settle")
                }
            }
            let state = JS_PromiseState(self.context, result)
            let promiseResult = JS_PromiseResult(self.context, result)
            cqjs_free_value(self.context, result)
            result = promiseResult
            if state == JS_PROMISE_REJECTED {
                defer { cqjs_free_value(self.context, result) }
                throw self.failure(from: result, redactionValues: redactionValues)
            }
        }
        return try ProviderPluginSnapshotMapper.map(
            QuickJSPluginValue(engine: self, value: result),
            provider: self.manifest.id,
            now: now)
    }

    private func installHostFunctions(on host: JSValue) throws {
        for (function, name, count) in [
            (QuickJSHostFunction.settingGet, "settingGet", 2),
            (.http, "http", 6),
            (.cookieHeader, "cookieHeader", 3),
            (.cacheGet, "cacheGet", 1),
            (.cacheSet, "cacheSet", 3),
            (.log, "log", 1),
            (.nextDailyReset, "nextDailyReset", 2),
            (.pct, "pct", 2),
            (.amountFromPercent, "amountFromPercent", 2),
        ] {
            let value = cqjs_new_host_function(self.context, function.rawValue, name, Int32(count))
            guard JS_SetPropertyStr(self.context, host, name, value) >= 0 else {
                throw self.scriptErrorFromException()
            }
        }
    }

    fileprivate func handleHostCall(
        _ function: QuickJSHostFunction,
        context _: OpaquePointer,
        arguments: UnsafeMutablePointer<JSValue>?,
        count: Int) -> JSValue
    {
        do {
            let values = UnsafeBufferPointer(start: arguments, count: count)
            switch function {
            case .defineProvider:
                guard let value = values.first else {
                    throw ProviderPluginError.invalidManifest("defineProvider(...) requires an object")
                }
                if let definition = self.definition {
                    cqjs_free_value(self.context, definition)
                }
                self.definition = cqjs_dup_value(self.context, value)
                return cqjs_undefined()
            case .settingGet:
                return try self.hostSettingGet(values)
            case .http:
                try self.hostHTTP(values)
                return cqjs_undefined()
            case .cookieHeader:
                try self.hostCookieHeader(values)
                return cqjs_undefined()
            case .cacheGet:
                return try self.hostCacheGet(values)
            case .cacheSet:
                try self.hostCacheSet(values)
                return cqjs_undefined()
            case .log:
                if let value = values.first, let state = self.fetchState {
                    let logger = CodexBarLog.logger(LogCategories.providerInstance(self.manifest.id, scope: "plugin"))
                    let message = try state.redactionValues.redact(self.string(from: value))
                    logger.debug("\(message)")
                }
                return cqjs_undefined()
            case .nextDailyReset:
                return try self.hostNextDailyReset(values)
            case .pct:
                return try self.hostPercentage(values)
            case .amountFromPercent:
                return try self.hostAmountFromPercent(values)
            }
        } catch {
            return self.throwError(error)
        }
    }

    private func hostSettingGet(_ arguments: UnsafeBufferPointer<JSValue>) throws -> JSValue {
        guard arguments.count >= 2, let state = self.fetchState else {
            throw ProviderPluginError.script("setting bridge is unavailable")
        }
        let key = try self.string(from: arguments[0])
        let secure = JS_ToBool(self.context, arguments[1]) == 1
        let expectedKind: ProviderPluginSetting.Kind = secure ? .secure : .plain
        guard self.manifest.settings.contains(where: { $0.key == key && $0.kind == expectedKind }) else {
            throw ProviderPluginError.secretAccess("\(expectedKind.rawValue) setting '\(key)' is not declared")
        }
        let values = secure ? state.secrets : state.settings
        guard let value = values[key], !value.isEmpty else { return cqjs_null() }
        return self.makeString(value)
    }

    private func hostHTTP(_ arguments: UnsafeBufferPointer<JSValue>) throws {
        guard arguments.count >= 6, let state = self.fetchState else {
            throw ProviderPluginError.http("HTTP bridge is unavailable")
        }
        do {
            let rawURL = try self.string(from: arguments[0])
            let options = try self.jsonDictionary(from: arguments[1])
            let method = try self.string(from: arguments[2])
            let wantsJSON = JS_ToBool(self.context, arguments[3]) == 1
            let request = try self.makeRequest(
                rawURL: rawURL,
                options: options,
                method: method,
                settings: state.settings,
                secrets: state.secrets)
            let response = try self.blockingValue(timeout: request.timeoutInterval) {
                try await self.transport.response(for: request)
            }
            guard response.data.count <= self.responseSizeLimit else {
                throw ProviderPluginError.http("response exceeded the \(self.responseSizeLimit)-byte limit")
            }
            if self.rejectsNonSuccessResponses, !(200..<300).contains(response.statusCode) {
                if let failure = ProviderPluginTransientHTTPFailure(
                    statusCode: response.statusCode,
                    retryAfterHeader: response.response.value(forHTTPHeaderField: "Retry-After"))
                {
                    throw failure
                }
                throw ProviderPluginError.http("request returned HTTP \(response.statusCode)")
            }
            if self.enforcesUserResponsePolicy,
               let encoding = response.response.value(forHTTPHeaderField: "Content-Encoding"),
               !encoding.isEmpty,
               encoding.caseInsensitiveCompare("identity") != .orderedSame
            {
                throw ProviderPluginError.http("compressed responses are not allowed")
            }
            let payload = try Self.responsePayload(response, wantsJSON: wantsJSON)
            let value = try self.parseJSON(payload)
            defer { cqjs_free_value(self.context, value) }
            try self.invoke(arguments[4], argument: value)
        } catch {
            try self.reject(arguments[5], error: error, redactionValues: state.redactionValues)
        }
    }

    private func hostCookieHeader(_ arguments: UnsafeBufferPointer<JSValue>) throws {
        guard arguments.count >= 3, let state = self.fetchState else {
            throw ProviderPluginError.secretAccess("cookie bridge is unavailable")
        }
        do {
            let domain = try self.string(from: arguments[0])
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard self.manifest.capabilities.contains(.browserCookies),
                  self.manifest.cookieDomains.contains(domain)
            else {
                throw ProviderPluginError.secretAccess("cookie domain is not declared")
            }
            let header: String
            if let provider = self.manifest.id.firstPartyProvider, let resolver = state.cookieResolver {
                header = try self.blockingValue(timeout: self.timeout) { try await resolver(provider, domain) }
            } else if let resolver = state.instanceCookieResolver {
                header = try self.blockingValue(timeout: self.timeout) { try await resolver(self.manifest.id, domain) }
            } else {
                throw ProviderPluginError.secretAccess("browser cookie access is unavailable")
            }
            state.redactionValues.insert(header)
            for pair in CookieHeaderNormalizer.pairs(from: header) {
                state.redactionValues.insert(pair.value)
            }
            let value = self.makeString(header)
            defer { cqjs_free_value(self.context, value) }
            try self.invoke(arguments[1], argument: value)
        } catch {
            try self.reject(arguments[2], error: error, redactionValues: state.redactionValues)
        }
    }

    private func hostCacheGet(_ arguments: UnsafeBufferPointer<JSValue>) throws -> JSValue {
        guard let keyValue = arguments.first else { return cqjs_undefined() }
        let key = try self.string(from: keyValue)
        guard let entry = self.cache[key], entry.expiresAt > Date() else {
            self.cache[key] = nil
            return cqjs_undefined()
        }
        return try self.parseJSON(entry.json)
    }

    private func hostCacheSet(_ arguments: UnsafeBufferPointer<JSValue>) throws {
        guard arguments.count >= 3 else { return }
        let key = try self.string(from: arguments[0])
        var ttl = 0.0
        guard JS_ToFloat64(self.context, &ttl, arguments[2]) == 0, ttl.isFinite, ttl > 0 else { return }
        let json = try self.jsonString(from: arguments[1])
        self.cache[key] = CacheEntry(json: json, expiresAt: Date().addingTimeInterval(min(ttl, 86400)))
    }

    private func hostNextDailyReset(_ arguments: UnsafeBufferPointer<JSValue>) throws -> JSValue {
        guard arguments.count >= 2
        else { throw ProviderPluginError.script("date bridge requires a time zone and hour") }
        let identifier = try self.string(from: arguments[0])
        var rawHour = 0.0
        guard JS_ToFloat64(self.context, &rawHour, arguments[1]) == 0,
              rawHour.isFinite,
              rawHour.rounded() == rawHour,
              (0...23).contains(rawHour),
              let timeZone = TimeZone(identifier: identifier)
        else {
            throw ProviderPluginError.script("invalid daily reset time zone or hour")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = Date()
        let start = calendar.startOfDay(for: now)
        var candidate = calendar.date(byAdding: .hour, value: Int(rawHour), to: start)!
        if candidate <= now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
        }
        return JS_NewFloat64(self.context, candidate.timeIntervalSince1970 * 1000)
    }

    private func hostPercentage(_ arguments: UnsafeBufferPointer<JSValue>) throws -> JSValue {
        guard arguments.count >= 2 else { return JS_NewFloat64(self.context, 100) }
        var used = 0.0
        var limit = 0.0
        guard JS_ToFloat64(self.context, &used, arguments[0]) == 0,
              JS_ToFloat64(self.context, &limit, arguments[1]) == 0,
              used.isFinite,
              limit.isFinite,
              limit > 0
        else { return JS_NewFloat64(self.context, 100) }
        return JS_NewFloat64(self.context, min(100, max(0, used / limit * 100)))
    }

    private func hostAmountFromPercent(_ arguments: UnsafeBufferPointer<JSValue>) throws -> JSValue {
        guard arguments.count >= 2 else { throw ProviderPluginError.script("percentage amount requires two numbers") }
        var percent = 0.0
        var limit = 0.0
        guard JS_ToFloat64(self.context, &percent, arguments[0]) == 0,
              JS_ToFloat64(self.context, &limit, arguments[1]) == 0
        else { throw ProviderPluginError.script("percentage amount requires two numbers") }
        return JS_NewFloat64(self.context, percent / 100 * limit)
    }

    private func makeRequest(
        rawURL: String,
        options: [String: Any],
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
        guard method == "GET" || method == "POST" else {
            throw ProviderPluginError.networkPolicy("HTTP method is not allowed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = try Self.timeoutSeconds(options)
        if method == "POST" {
            guard let bodyJSON = options["bodyJSON"] as? String else {
                throw ProviderPluginError.http("POST JSON body is missing")
            }
            request.httpBody = Data(bodyJSON.utf8)
        }
        if let headers = options["headers"] as? [String: Any] {
            for (name, rawValue) in headers {
                guard let value = rawValue as? String else {
                    throw ProviderPluginError.http("request header '\(name)' must be a string")
                }
                if let auth = self.manifest.auth, name.caseInsensitiveCompare(auth.header) == .orderedSame {
                    throw ProviderPluginError.networkPolicy("plugins may not override the auth header")
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if self.enforcesUserResponsePolicy {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let auth = self.manifest.auth {
            var secretName = auth.secret
            if let requestedSecret = options["authSecret"] {
                guard let requestedSecret = requestedSecret as? String,
                      self.manifest.settings.first(where: { $0.key == requestedSecret })?.kind == .secure
                else {
                    throw ProviderPluginError.secretAccess(
                        "request auth secret must name a declared secure setting")
                }
                secretName = requestedSecret
            }
            guard let credential = secrets[secretName], !credential.isEmpty else {
                throw ProviderPluginError.secretAccess("required auth secret is unavailable")
            }
            let value = switch auth.type {
            case .bearer: "Bearer \(credential)"
            case .authorizationScheme: "\(auth.scheme!) \(credential)"
            case .xAPIKey, .header: credential
            }
            request.setValue(value, forHTTPHeaderField: auth.header)
        }
        return request
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

    private static func timeoutSeconds(_ options: [String: Any]) throws -> TimeInterval {
        guard let value = options["timeoutSeconds"] else { return 15 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ProviderPluginError.http("timeoutSeconds must be a number from 1 through 30")
        }
        let seconds = number.doubleValue
        guard seconds.isFinite, (1...30).contains(seconds) else {
            throw ProviderPluginError.http("timeoutSeconds must be a number from 1 through 30")
        }
        return seconds
    }

    private static func responsePayload(_ response: ProviderHTTPResponse, wantsJSON: Bool) throws -> [String: Any] {
        var headers: [String: String] = [:]
        for (key, value) in response.response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var payload: [String: Any] = ["status": response.statusCode, "headers": headers]
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

    private func blockingValue<Value: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value) throws -> Value
    {
        let fetchDeadline = self.fetchState?.deadline ?? Date().addingTimeInterval(timeout)
        let box = QuickJSBlockingResult<Value>()
        let task = Task.detached {
            box.markStarted()
            do {
                let value = try await operation()
                box.finish(.success(value))
            } catch {
                box.finish(.failure(error))
            }
        }
        defer { task.cancel() }
        return try box.value(timeout: timeout, fetchDeadline: fetchDeadline, watchdog: self.watchdog)
    }

    private func invoke(_ function: JSValue, argument: JSValue) throws {
        let result = try self.call(function, arguments: [argument])
        cqjs_free_value(self.context, result)
    }

    private func reject(
        _ function: JSValue,
        error: Error,
        redactionValues: QuickJSRedactionValues) throws
    {
        let value = self.makeString(redactionValues.redact(error.localizedDescription))
        defer { cqjs_free_value(self.context, value) }
        try self.invoke(function, argument: value)
    }

    private func call(_ function: JSValue, arguments: [JSValue]) throws -> JSValue {
        JS_UpdateStackTop(self.runtime)
        var mutableArguments = arguments
        let result = mutableArguments.withUnsafeMutableBufferPointer { buffer in
            JS_Call(self.context, function, cqjs_undefined(), Int32(buffer.count), buffer.baseAddress)
        }
        guard !cqjs_is_exception(result) else { throw self.scriptErrorFromException() }
        return result
    }

    private func evaluate(_ source: String, filename: String) throws -> JSValue {
        JS_UpdateStackTop(self.runtime)
        let result = source.utf8CString.withUnsafeBufferPointer { sourceBuffer in
            filename.withCString { filenamePointer in
                JS_Eval(
                    self.context,
                    sourceBuffer.baseAddress,
                    sourceBuffer.count - 1,
                    filenamePointer,
                    JS_EVAL_TYPE_GLOBAL)
            }
        }
        guard !cqjs_is_exception(result) else { throw self.scriptErrorFromException() }
        return result
    }

    private func scriptErrorFromException() -> Error {
        if let watchdog = self.watchdog, cqjs_watchdog_is_interrupted(watchdog) {
            let exception = JS_GetException(self.context)
            cqjs_free_value(self.context, exception)
            return ProviderPluginError.timedOut
        }
        let exception = JS_GetException(self.context)
        defer { cqjs_free_value(self.context, exception) }
        return ProviderPluginError.script((try? self.message(from: exception)) ?? "unknown QuickJS exception")
    }

    private func failure(from value: JSValue, redactionValues: QuickJSRedactionValues) -> Error {
        let message = redactionValues.redact((try? self.message(from: value)) ?? "unknown plugin failure")
        if let classified = ProviderPluginClassifiedFailureParser.error(from: message) {
            return classified
        }
        return ProviderPluginError.script(message)
    }

    private func message(from value: JSValue) throws -> String {
        if cqjs_is_object(value) {
            let message = JS_GetPropertyStr(self.context, value, "message")
            defer { cqjs_free_value(self.context, message) }
            if cqjs_is_string(message) {
                return try self.string(from: message)
            }
        }
        return try self.string(from: value)
    }

    private func throwError(_ error: Error) -> JSValue {
        error.localizedDescription.withCString { cqjs_throw_error(self.context, $0) }
    }

    private func makeString(_ value: String) -> JSValue {
        value.utf8CString.withUnsafeBufferPointer { buffer in
            JS_NewStringLen(self.context, buffer.baseAddress, buffer.count - 1)
        }
    }

    fileprivate func string(from value: JSValue) throws -> String {
        var length = 0
        guard let pointer = JS_ToCStringLen2(self.context, &length, value, false) else {
            throw self.scriptErrorFromException()
        }
        defer { JS_FreeCString(self.context, pointer) }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        guard let string = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            throw ProviderPluginError.script("QuickJS string was not valid UTF-8")
        }
        return string
    }

    private func jsonString(from value: JSValue) throws -> String {
        let result = JS_JSONStringify(self.context, value, cqjs_undefined(), cqjs_undefined())
        guard !cqjs_is_exception(result), !cqjs_is_undefined(result) else {
            if cqjs_is_exception(result) {
                throw self.scriptErrorFromException()
            }
            throw ProviderPluginError.script("value is not JSON-serializable")
        }
        defer { cqjs_free_value(self.context, result) }
        return try self.string(from: result)
    }

    private func jsonObject(from value: JSValue) throws -> Any {
        let data = try Data(self.jsonString(from: value).utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func jsonDictionary(from value: JSValue) throws -> [String: Any] {
        guard let dictionary = try self.jsonObject(from: value) as? [String: Any] else {
            throw ProviderPluginError.http("request options must be an object")
        }
        return dictionary
    }

    private func parseJSON(_ object: Any) throws -> JSValue {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProviderPluginError.script("could not encode host JSON")
        }
        return try self.parseJSON(string)
    }

    private func parseJSON(_ string: String) throws -> JSValue {
        let result = string.utf8CString.withUnsafeBufferPointer { buffer in
            JS_ParseJSON(self.context, buffer.baseAddress, buffer.count - 1, "<host-json>")
        }
        guard !cqjs_is_exception(result) else { throw self.scriptErrorFromException() }
        return result
    }
}

private final class QuickJSSerialWorker: @unchecked Sendable {
    typealias Job = () -> Void

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job] = []
        private var acceptsJobs = true
        private var stopped = false

        func enqueue(_ job: @escaping Job) -> Bool {
            self.condition.lock()
            defer { self.condition.unlock() }
            guard self.acceptsJobs else { return false }
            self.jobs.append(job)
            self.condition.signal()
            return true
        }

        func next() -> Job? {
            self.condition.lock()
            defer { self.condition.unlock() }
            while self.jobs.isEmpty, self.acceptsJobs {
                self.condition.wait()
            }
            guard !self.jobs.isEmpty else { return nil }
            return self.jobs.removeFirst()
        }

        func beginShutdown() {
            self.condition.lock()
            self.acceptsJobs = false
            self.condition.broadcast()
            self.condition.unlock()
        }

        func markStopped() {
            self.condition.lock()
            self.stopped = true
            self.condition.broadcast()
            self.condition.unlock()
        }

        func waitUntilStopped() {
            self.condition.lock()
            while !self.stopped {
                self.condition.wait()
            }
            self.condition.unlock()
        }
    }

    /// A Thread subclass with an overridden main() instead of Thread(block:): the block closure
    /// picks up @MainActor inference under some SDKs (Xcode 26.3), and the embedded executor
    /// check then traps on the first job when the OS runtime enforces isolation dynamically.
    private final class WorkerThread: Thread {
        private let state: State

        init(state: State) {
            self.state = state
            super.init()
        }

        override func main() {
            defer { self.state.markStopped() }
            while let job = self.state.next() {
                job()
            }
        }
    }

    private let state: State
    private let thread: WorkerThread

    init(name: String, stackSizeBytes: Int) {
        let state = State()
        self.state = state
        self.thread = WorkerThread(state: state)
        self.thread.name = name
        self.thread.stackSize = stackSizeBytes
        self.thread.start()
    }

    deinit {
        self.shutdown()
    }

    var isCurrentThread: Bool {
        Thread.current === self.thread
    }

    func async(_ operation: @escaping Job) {
        precondition(self.state.enqueue(operation), "QuickJS worker accepted work after shutdown")
    }

    func sync<Value: Sendable>(_ operation: @escaping () throws -> Value) throws -> Value {
        if self.isCurrentThread {
            return try operation()
        }
        let box = QuickJSBlockingResult<Value>()
        precondition(self.state.enqueue {
            box.finish(Result { try operation() })
        }, "QuickJS worker accepted work after shutdown")
        return try box.wait().get()
    }

    func shutdown() {
        self.state.beginShutdown()
        if !self.isCurrentThread {
            self.state.waitUntilStopped()
        }
    }
}

final class QuickJSBlockingResult<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var startedAt: Date?
    private var result: Result<Value, Error>?

    func markStarted() {
        self.condition.lock()
        self.startedAt = Date()
        self.condition.broadcast()
        self.condition.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        self.condition.lock()
        self.result = result
        self.condition.broadcast()
        self.condition.unlock()
    }

    func value(
        timeout: TimeInterval,
        fetchDeadline: Date,
        watchdog: OpaquePointer?) throws -> Value
    {
        var startedAt: Date?
        while true {
            let deadline = startedAt.map {
                $0.addingTimeInterval(min(timeout, max(0, fetchDeadline.timeIntervalSince($0))))
            } ?? fetchDeadline
            let now = Date()
            guard now < deadline else { throw URLError(.timedOut) }
            let state = self.wait(
                until: min(deadline, now.addingTimeInterval(0.05)),
                waitingForStart: startedAt == nil)
            if let result = state.result {
                return try result.get()
            }
            startedAt = state.startedAt
            if let watchdog, cqjs_watchdog_is_interrupted(watchdog) {
                throw ProviderPluginError.timedOut
            }
        }
    }

    func wait(until deadline: Date) -> Result<Value, Error>? {
        self.wait(until: deadline, waitingForStart: false).result
    }

    func wait(
        until deadline: Date,
        waitingForStart: Bool) -> (startedAt: Date?, result: Result<Value, Error>?)
    {
        self.condition.lock()
        defer { self.condition.unlock() }
        if self.result == nil, !waitingForStart || self.startedAt == nil {
            _ = self.condition.wait(until: deadline)
        }
        return (self.startedAt, self.result)
    }

    func wait() -> Result<Value, Error> {
        self.condition.lock()
        defer { self.condition.unlock() }
        while self.result == nil {
            self.condition.wait()
        }
        guard let result = self.result else {
            preconditionFailure("QuickJS blocking result signaled without a value")
        }
        return result
    }
}

private final class QuickJSRedactionValues: @unchecked Sendable {
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
            self.values.reduce(message) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
        }
    }
}
