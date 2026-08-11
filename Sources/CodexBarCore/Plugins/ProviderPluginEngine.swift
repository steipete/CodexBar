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
        completion: @escaping @Sendable (Result<UsageSnapshot, Error>) -> Void)

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
    var isDate: Bool { get }

    func property(_ name: String) -> (any ProviderPluginValue)?
    func element(at index: Int) -> (any ProviderPluginValue)?
    func stringValue() -> String
    func int32Value() -> Int32
    func doubleValue() -> Double
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

    var isDate: Bool {
        false
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

    func dateValue() -> Date? {
        nil
    }
}

#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore

final class JavaScriptCorePluginValue: ProviderPluginValue {
    let value: JSValue

    init(_ value: JSValue) {
        self.value = value
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

    var isDate: Bool {
        self.value.isDate
    }

    func property(_ name: String) -> (any ProviderPluginValue)? {
        self.value.forProperty(name).map(JavaScriptCorePluginValue.init)
    }

    func element(at index: Int) -> (any ProviderPluginValue)? {
        self.value.atIndex(index).map(JavaScriptCorePluginValue.init)
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

    func dateValue() -> Date? {
        self.value.toDate()
    }
}
#endif
