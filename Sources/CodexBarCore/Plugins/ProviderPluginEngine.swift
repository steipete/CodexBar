import CoreFoundation
import Foundation

public enum ProviderPluginEngineKind: Equatable, Sendable {
    case automatic
    case javaScriptCore
    case quickJS
}

struct ProviderPluginContextOptions: Sendable {
    static let production = Self(optionalRequestTimeoutSeconds: nil)

    let optionalRequestTimeoutSeconds: TimeInterval?
    // Internal test control; public runtime initializers always use the production budget.
    var optionalCollectionBudget: Duration = .milliseconds(200)
    var storage: ProviderPluginStorage?
    var beforeHTTPAttempt: (@Sendable () async throws -> Void)?
    var cookieSource: ProviderCookieSource = .auto
    var cookieInvalidator: ProviderPluginRuntime.CookieInvalidator?
    var cookieSessionResolver: ProviderPluginRuntime.CookieSessionResolver?
    var cookieSessionInvalidator: ProviderPluginRuntime.CookieSessionInvalidator?

    func rejectCookie(domain: String, id: String) {
        if !id.isEmpty, let invalidate = self.cookieSessionInvalidator {
            invalidate(domain, id)
        } else {
            self.cookieInvalidator?(domain)
        }
    }
}

enum ProviderPluginSourceLint {
    static func validateBundled(_ source: String, name: String) throws {
        if source.range(of: #"\bIntl\s*\."#, options: .regularExpression) != nil {
            throw ProviderPluginError.load("bundled plugin '\(name)' references engine-dependent Intl")
        }
    }
}

enum ProviderPluginEngineFactory {
    // swiftlint:disable:next function_parameter_count
    static func make(
        kind: ProviderPluginEngineKind,
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        timeout: TimeInterval,
        responseSizeLimit: Int,
        enforcesUserResponsePolicy: Bool,
        allowsDynamicID: Bool) throws -> any ProviderPluginEngine
    {
        switch kind {
        case .automatic:
            preconditionFailure("automatic plugin engine selection must be resolved by ProviderPluginRuntime")
        case .javaScriptCore:
            #if canImport(JavaScriptCore)
            return try JavaScriptCoreProviderPluginEngine.make(
                source: source,
                preludeSource: preludeSource,
                transport: transport,
                responseSizeLimit: responseSizeLimit,
                enforcesUserResponsePolicy: enforcesUserResponsePolicy,
                allowsDynamicID: allowsDynamicID)
            #else
            throw ProviderPluginError.load("JavaScriptCore is unavailable on this platform")
            #endif
        case .quickJS:
            return try QuickJSProviderPluginEngine.make(
                source: source,
                preludeSource: preludeSource,
                transport: transport,
                timeout: timeout,
                responseSizeLimit: responseSizeLimit,
                enforcesUserResponsePolicy: enforcesUserResponsePolicy,
                allowsDynamicID: allowsDynamicID)
        }
    }
}

protocol ProviderPluginEngine: AnyObject, Sendable {
    var manifest: ProviderPluginManifest { get }

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

    func globalType(of name: String) throws -> String
    func requestInterrupt()
}

protocol ProviderPluginValue {
    var isObject: Bool { get }
    var isArray: Bool { get }
    var isNull: Bool { get }
    var isUndefined: Bool { get }
    var isString: Bool { get }
    var isNumber: Bool { get }
    var isBoolean: Bool { get }
    var isDate: Bool { get }

    func propertyNames() throws -> [String]
    func property(_ name: String) -> (any ProviderPluginValue)?
    func element(at index: Int) -> (any ProviderPluginValue)?
    func stringValue() -> String
    func int32Value() -> Int32
    func doubleValue() -> Double
    func boolValue() -> Bool
    func dateValue() -> Date?
}

final class JSONProviderPluginValue: ProviderPluginValue {
    private let value: Any

    init(_ value: Any) {
        self.value = value
    }

    var isObject: Bool {
        self.value is [String: Any] || self.value is [Any]
    }

    var isArray: Bool {
        self.value is [Any]
    }

    var isNull: Bool {
        self.value is NSNull
    }

    var isUndefined: Bool {
        false
    }

    var isString: Bool {
        self.value is String
    }

    var isNumber: Bool {
        guard let number = self.value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    var isBoolean: Bool {
        guard let number = self.value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    var isDate: Bool {
        false
    }

    func propertyNames() throws -> [String] {
        let keys = Array((self.value as? [String: Any] ?? [:]).keys)
        guard keys.count <= 64 else { throw ProviderPluginError.invalidSnapshot("object exceeds 64 keys") }
        return keys
    }

    func property(_ name: String) -> (any ProviderPluginValue)? {
        if let object = self.value as? [String: Any], let value = object[name] {
            return JSONProviderPluginValue(value)
        }
        if name == "length", let array = self.value as? [Any] {
            return JSONProviderPluginValue(NSNumber(value: array.count))
        }
        return nil
    }

    func element(at index: Int) -> (any ProviderPluginValue)? {
        guard let array = self.value as? [Any], array.indices.contains(index) else { return nil }
        return JSONProviderPluginValue(array[index])
    }

    func stringValue() -> String {
        self.value as? String ?? String(describing: self.value)
    }

    func int32Value() -> Int32 {
        (self.value as? NSNumber)?.int32Value ?? 0
    }

    func doubleValue() -> Double {
        (self.value as? NSNumber)?.doubleValue ?? .nan
    }

    func boolValue() -> Bool {
        (self.value as? NSNumber)?.boolValue ?? false
    }

    func dateValue() -> Date? {
        nil
    }
}

#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore

final class JavaScriptCorePluginValue: ProviderPluginValue {
    let value: JSValue
    private let keyEnumerator: JSValue

    init(_ value: JSValue, keyEnumerator: JSValue) {
        self.value = value
        self.keyEnumerator = keyEnumerator
    }

    var isObject: Bool {
        self.value.isObject
    }

    var isArray: Bool {
        self.value.isArray
    }

    var isNull: Bool {
        self.value.isNull
    }

    var isUndefined: Bool {
        self.value.isUndefined
    }

    var isString: Bool {
        self.value.isString
    }

    var isNumber: Bool {
        self.value.isNumber
    }

    var isBoolean: Bool {
        self.value.isBoolean
    }

    var isDate: Bool {
        self.value.isDate
    }

    func propertyNames() throws -> [String] {
        guard let keys = self.keyEnumerator.call(withArguments: [self.value]), keys.isArray else {
            throw ProviderPluginError.invalidSnapshot("cannot enumerate result keys")
        }
        let count = keys.forProperty("length").toDouble()
        guard count <= 64 else { throw ProviderPluginError.invalidSnapshot("object exceeds 64 keys") }
        return try (0..<Int(count)).map { index in
            guard let key = keys.atIndex(index), key.isString else {
                throw ProviderPluginError.invalidSnapshot("symbol result keys are not supported")
            }
            return key.toString()
        }
    }

    func property(_ name: String) -> (any ProviderPluginValue)? {
        self.value.forProperty(name).map { JavaScriptCorePluginValue($0, keyEnumerator: self.keyEnumerator) }
    }

    func element(at index: Int) -> (any ProviderPluginValue)? {
        self.value.atIndex(index).map { JavaScriptCorePluginValue($0, keyEnumerator: self.keyEnumerator) }
    }

    func stringValue() -> String {
        self.value.toString()
    }

    func int32Value() -> Int32 {
        self.value.toInt32()
    }

    func doubleValue() -> Double {
        self.value.toDouble()
    }

    func boolValue() -> Bool {
        self.value.toBool()
    }

    func dateValue() -> Date? {
        self.value.toDate()
    }
}
#endif

final class ProviderPluginRedactionValues: @unchecked Sendable {
    let transportErrors = ProviderPluginHTTPResponse.TransportErrors()
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
