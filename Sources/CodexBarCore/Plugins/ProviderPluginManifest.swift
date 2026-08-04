#if canImport(JavaScriptCore)
import Foundation
@preconcurrency import JavaScriptCore

public struct ProviderPluginSetting: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case plain
        case secure
    }

    public let key: String
    public let title: String
    public let subtitle: String?
    public let kind: Kind

    public init(key: String, title: String, subtitle: String? = nil, kind: Kind = .secure) {
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

public struct ProviderPluginIcon: Equatable, Sendable {
    public let monogram: String
    public let tint: String

    public init(monogram: String, tint: String) {
        self.monogram = monogram
        self.tint = tint
    }
}

public struct ProviderPluginAuth: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case bearer
        case xAPIKey = "x-api-key"
        case header
        case authorizationScheme = "authorization-scheme"
    }

    public let type: Kind
    public let header: String
    public let secret: String
    public let scheme: String?

    public init(type: Kind, header: String, secret: String, scheme: String? = nil) {
        self.type = type
        self.header = header
        self.secret = secret
        self.scheme = scheme
    }
}

public enum ProviderPluginEndpoint: Equatable, Hashable, Sendable {
    public enum Policy: String, Sendable {
        case https
        case httpsOrLoopbackHTTP = "https-or-loopback-http"
    }

    case fixed(String)
    case setting(key: String, policy: Policy)
}

public enum ProviderPluginCapability: String, Hashable, Sendable {
    case browserCookies = "browser-cookies"
}

public struct ProviderPluginManifest: @unchecked Sendable {
    public let id: ProviderInstanceID
    public let name: String
    public let icon: ProviderPluginIcon
    public let endpoints: Set<ProviderPluginEndpoint>
    public let auth: ProviderPluginAuth?
    public let settings: [ProviderPluginSetting]
    public let capabilities: Set<ProviderPluginCapability>
    public let cookieDomains: Set<String>

    let fetchUsage: JSValue

    // Manifest parsing validates the complete security surface in one pass.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init(definition: JSValue, allowsDynamicID: Bool = false) throws {
        guard definition.isObject else {
            throw ProviderPluginError.invalidManifest("defineProvider(...) requires an object")
        }

        let rawID = try Self.requiredString(definition, property: "id")
        guard let id = ProviderInstanceID(rawValue: rawID) else {
            throw ProviderPluginError.invalidManifest(
                "provider id must contain 1-64 lowercase ASCII letters, digits, or hyphens")
        }
        guard allowsDynamicID || id.firstPartyProvider != nil else {
            throw ProviderPluginError.invalidManifest(
                "provider id '\(rawID)' must match an existing UsageProvider raw value")
        }
        self.id = id
        self.name = try Self.boundedString(definition, property: "name", maximumLength: 80)
        self.icon = try Self.parseIcon(definition.forProperty("icon"), fallbackName: self.name)

        let endpointValue = definition.forProperty("endpoints")
        guard let endpointValue, endpointValue.isArray else {
            throw ProviderPluginError.invalidManifest("'endpoints' must be a non-empty array of HTTPS origins")
        }
        let endpointCount = Int(endpointValue.forProperty("length")?.toInt32() ?? 0)
        guard (1...16).contains(endpointCount) else {
            throw ProviderPluginError.invalidManifest("'endpoints' must not be empty")
        }
        var endpoints: Set<ProviderPluginEndpoint> = []
        for index in 0..<endpointCount {
            guard let rawEndpoint = endpointValue.atIndex(index) else {
                throw ProviderPluginError.invalidManifest("endpoint at index \(index) is missing")
            }
            if rawEndpoint.isString {
                try endpoints.insert(.fixed(ProviderPluginOrigin.normalizedOrigin(rawEndpoint.toString())))
                continue
            }
            guard rawEndpoint.isObject else {
                throw ProviderPluginError.invalidManifest(
                    "endpoint at index \(index) must be an HTTPS origin or setting endpoint")
            }
            let key = try Self.requiredString(rawEndpoint, property: "setting")
            let rawPolicy = try Self.requiredString(rawEndpoint, property: "policy")
            guard let policy = ProviderPluginEndpoint.Policy(rawValue: rawPolicy) else {
                throw ProviderPluginError.invalidManifest("unsupported endpoint policy '\(rawPolicy)'")
            }
            endpoints.insert(.setting(key: key, policy: policy))
        }
        self.endpoints = endpoints

        guard let settingsValue = definition.forProperty("settings"), settingsValue.isArray else {
            throw ProviderPluginError.invalidManifest("'settings' must be an array")
        }
        let settingCount = Int(settingsValue.forProperty("length")?.toInt32() ?? 0)
        guard settingCount <= 32 else {
            throw ProviderPluginError.invalidManifest("'settings' exceeds 32 entries")
        }
        var settings: [ProviderPluginSetting] = []
        var settingKeys: Set<String> = []
        for index in 0..<settingCount {
            guard let setting = settingsValue.atIndex(index), setting.isObject else {
                throw ProviderPluginError.invalidManifest("setting at index \(index) must be an object")
            }
            let key = try Self.requiredString(setting, property: "key")
            guard Self.isValidSettingKey(key) else {
                throw ProviderPluginError.invalidManifest(
                    "setting key '\(key)' must contain 1-64 ASCII letters, digits, " +
                        "or underscores and start with a letter")
            }
            guard settingKeys.insert(key).inserted else {
                throw ProviderPluginError.invalidManifest("duplicate setting key '\(key)'")
            }
            let title = try Self.boundedString(setting, property: "title", maximumLength: 80)
            let subtitle = try Self.optionalBoundedString(setting, property: "subtitle", maximumLength: 256)
            let rawKind = try Self.optionalString(setting, property: "type") ?? "secure"
            guard let kind = ProviderPluginSetting.Kind(rawValue: rawKind) else {
                throw ProviderPluginError.invalidManifest("unsupported setting type '\(rawKind)'")
            }
            settings.append(ProviderPluginSetting(key: key, title: title, subtitle: subtitle, kind: kind))
        }
        for endpoint in endpoints {
            guard case let .setting(key, _) = endpoint else { continue }
            guard settings.first(where: { $0.key == key })?.kind == .plain else {
                throw ProviderPluginError.invalidManifest(
                    "endpoint setting '\(key)' must be declared as a plain setting")
            }
        }
        self.settings = settings

        if let authValue = definition.forProperty("auth"), !authValue.isUndefined, !authValue.isNull {
            guard authValue.isObject else {
                throw ProviderPluginError.invalidManifest("'auth' must be an object when present")
            }
            let rawAuthType = try Self.requiredString(authValue, property: "type")
            guard let authType = ProviderPluginAuth.Kind(rawValue: rawAuthType) else {
                throw ProviderPluginError.invalidManifest("unsupported auth type '\(rawAuthType)'")
            }
            let secret = try Self.requiredString(authValue, property: "secret")
            let header: String = switch authType {
            case .bearer, .authorizationScheme:
                "Authorization"
            case .xAPIKey:
                "X-API-Key"
            case .header:
                try Self.requiredString(authValue, property: "header")
            }
            let scheme: String? = if authType == .authorizationScheme {
                try Self.requiredString(authValue, property: "scheme")
            } else {
                nil
            }
            guard Self.isValidHeaderName(header) else {
                throw ProviderPluginError.invalidManifest("auth header '\(header)' is invalid")
            }
            if let scheme, !Self.isValidAuthorizationScheme(scheme) {
                throw ProviderPluginError.invalidManifest("authorization scheme '\(scheme)' is invalid")
            }
            guard settings.first(where: { $0.key == secret })?.kind == .secure else {
                throw ProviderPluginError.invalidManifest(
                    "auth secret '\(secret)' must be declared as a secure setting")
            }
            self.auth = ProviderPluginAuth(type: authType, header: header, secret: secret, scheme: scheme)
        } else {
            self.auth = nil
        }

        let capabilitiesValue = definition.forProperty("capabilities")
        var capabilities: Set<ProviderPluginCapability> = []
        if let capabilitiesValue, !capabilitiesValue.isUndefined, !capabilitiesValue.isNull {
            guard capabilitiesValue.isArray else {
                throw ProviderPluginError.invalidManifest("'capabilities' must be an array when present")
            }
            let count = Int(capabilitiesValue.forProperty("length")?.toInt32() ?? 0)
            for index in 0..<count {
                guard let value = capabilitiesValue.atIndex(index), value.isString,
                      let capability = ProviderPluginCapability(rawValue: value.toString())
                else {
                    throw ProviderPluginError.invalidManifest("unsupported capability at index \(index)")
                }
                capabilities.insert(capability)
            }
        }
        self.capabilities = capabilities

        let cookieDomainsValue = definition.forProperty("cookieDomains")
        var cookieDomains: Set<String> = []
        if let cookieDomainsValue, !cookieDomainsValue.isUndefined, !cookieDomainsValue.isNull {
            guard capabilities.contains(.browserCookies), cookieDomainsValue.isArray else {
                throw ProviderPluginError.invalidManifest(
                    "'cookieDomains' requires the browser-cookies capability and must be an array")
            }
            let count = Int(cookieDomainsValue.forProperty("length")?.toInt32() ?? 0)
            for index in 0..<count {
                guard let value = cookieDomainsValue.atIndex(index), value.isString else {
                    throw ProviderPluginError.invalidManifest("cookie domain at index \(index) must be a string")
                }
                try cookieDomains.insert(Self.normalizedCookieDomain(value.toString()))
            }
            guard !cookieDomains.isEmpty else {
                throw ProviderPluginError.invalidManifest("'cookieDomains' must not be empty")
            }
        }
        if capabilities.contains(.browserCookies), cookieDomains.isEmpty {
            throw ProviderPluginError.invalidManifest(
                "the browser-cookies capability requires at least one declared cookie domain")
        }
        self.cookieDomains = cookieDomains

        guard let fetchUsage = definition.forProperty("fetchUsage"), fetchUsage.isObject else {
            throw ProviderPluginError.invalidManifest("'fetchUsage' must be a function")
        }
        self.fetchUsage = fetchUsage
    }

    private static func requiredString(_ object: JSValue, property: String) throws -> String {
        guard let value = object.forProperty(property), value.isString else {
            throw ProviderPluginError.invalidManifest("'\(property)' must be a string")
        }
        let string = value.toString().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else {
            throw ProviderPluginError.invalidManifest("'\(property)' must not be empty")
        }
        return string
    }

    private static func optionalString(_ object: JSValue, property: String) throws -> String? {
        guard let value = object.forProperty(property), !value.isUndefined, !value.isNull else { return nil }
        guard value.isString else {
            throw ProviderPluginError.invalidManifest("'\(property)' must be a string when present")
        }
        return value.toString()
    }

    private static func boundedString(_ object: JSValue, property: String, maximumLength: Int) throws -> String {
        let value = try Self.requiredString(object, property: property)
        guard value.utf8.count <= maximumLength else {
            throw ProviderPluginError.invalidManifest("'\(property)' exceeds \(maximumLength) UTF-8 bytes")
        }
        return value
    }

    private static func optionalBoundedString(
        _ object: JSValue,
        property: String,
        maximumLength: Int) throws -> String?
    {
        guard let raw = try optionalString(object, property: property) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maximumLength else {
            throw ProviderPluginError.invalidManifest("'\(property)' exceeds \(maximumLength) UTF-8 bytes")
        }
        return value.isEmpty ? nil : value
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
        }
    }

    private static func isValidAuthorizationScheme(_ value: String) -> Bool {
        value.utf8.count <= 32 && self.isValidHeaderName(value)
    }

    private static func isValidSettingKey(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), let first = value.utf8.first,
              (65...90).contains(first) || (97...122).contains(first)
        else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
        }
    }

    private static func parseIcon(_ value: JSValue?, fallbackName: String) throws -> ProviderPluginIcon {
        let fallback = String(fallbackName.prefix(1)).uppercased()
        guard let value, !value.isUndefined, !value.isNull else {
            return ProviderPluginIcon(monogram: fallback, tint: "#6B7280")
        }
        guard value.isObject else {
            throw ProviderPluginError.invalidManifest("'icon' must be an object when present")
        }
        let monogram = try Self.optionalString(value, property: "monogram")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        guard (1...3).contains(monogram.count), monogram.utf8.count <= 12 else {
            throw ProviderPluginError.invalidManifest("icon monogram must contain 1-3 characters")
        }
        let tint = try Self.optionalString(value, property: "tint") ?? "#6B7280"
        guard tint.utf8.count == 7,
              tint.utf8.first == UInt8(ascii: "#"),
              tint.utf8.dropFirst().allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw ProviderPluginError.invalidManifest("icon tint must be a #RRGGBB color")
        }
        return ProviderPluginIcon(monogram: monogram, tint: tint.uppercased())
    }

    private static func normalizedCookieDomain(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 253,
              !value.hasPrefix("."), !value.hasSuffix("."), !value.contains("/"), !value.contains(":")
        else {
            throw ProviderPluginError.invalidManifest("cookie domain '\(rawValue)' is invalid")
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { byte in
                    (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
                }
        }) else {
            throw ProviderPluginError.invalidManifest("cookie domain '\(rawValue)' is invalid")
        }
        return value
    }
}

enum ProviderPluginOrigin {
    static func normalizedOrigin(_ rawValue: String) throws -> String {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw ProviderPluginError.invalidManifest("endpoint '\(rawValue)' must be an HTTPS origin")
        }
        let port = components.port
        return "https://\(self.formattedHost(host))\(port == nil || port == 443 ? "" : ":\(port!)")"
    }

    static func normalizedOrigin(of url: URL) throws -> String {
        try self.normalizedOrigin(of: url, policy: .https)
    }

    static func normalizedOrigin(of url: URL, policy: ProviderPluginEndpoint.Policy) throws -> String {
        let validator = ProviderEndpointOverrideValidator()
        let validated: URL? = switch policy {
        case .https:
            validator.validatedURL(url.absoluteString)
        case .httpsOrLoopbackHTTP:
            validator.validatedURLAllowingLoopbackHTTP(url.absoluteString)
        }
        guard let validated, validated.fragment == nil, validated.user == nil, validated.password == nil else {
            throw ProviderPluginError.networkPolicy("URL does not satisfy the declared endpoint policy")
        }
        guard let scheme = validated.scheme?.lowercased(), let host = validated.host?.lowercased(), !host.isEmpty else {
            throw ProviderPluginError.networkPolicy("request URL has no host")
        }
        let port = validated.port
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(self.formattedHost(host))\(port == nil || port == defaultPort ? "" : ":\(port!)")"
    }

    private static func formattedHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}

public enum ProviderPluginError: LocalizedError, Sendable, Equatable {
    case load(String)
    case invalidManifest(String)
    case networkPolicy(String)
    case http(String)
    case secretAccess(String)
    case invalidSnapshot(String)
    case script(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .load(message): "Provider plugin load failed: \(message)"
        case let .invalidManifest(message): "Invalid provider plugin manifest: \(message)"
        case let .networkPolicy(message): "Provider plugin network policy rejected the request: \(message)"
        case let .http(message): "Provider plugin HTTP error: \(message)"
        case let .secretAccess(message): "Provider plugin secret access denied: \(message)"
        case let .invalidSnapshot(message): "Invalid provider plugin snapshot: \(message)"
        case let .script(message): "Provider plugin script failed: \(message)"
        case .timedOut: "Provider plugin timed out"
        }
    }
}
#endif
