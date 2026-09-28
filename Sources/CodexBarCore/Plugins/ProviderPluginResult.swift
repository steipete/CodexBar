import Foundation

public struct ProviderPluginResult: Sendable {
    public let usage: UsageSnapshot
    public let sourceLabel: String?
    public let persist: [String: String]
}

public enum ProviderSettingsSaveOutcome: Sendable, Equatable {
    case saved, unchanged, stale, failed

    var diagnostic: String? {
        switch self {
        case .saved, .unchanged: nil
        case .stale: "Discovered provider settings were not saved because the account settings changed."
        case .failed: "Usage refreshed, but discovered provider settings could not be saved."
        }
    }
}

/// Only descriptors grant card and plain-setting capabilities; scripts cannot expand these allowlists.
public struct ProviderPluginResultPolicy: Sendable {
    typealias CardMapper = @Sendable (any ProviderPluginValue, UsageSnapshot, Date) throws -> UsageSnapshot
    typealias SettingWriter = @Sendable (String, inout ProviderConfig) throws -> Void
    let cardMapper: CardMapper?
    let settings: [String: SettingWriter]

    public init() {
        self.cardMapper = nil
        self.settings = [:]
    }

    init(cardMapper: CardMapper? = nil, settings: [String: SettingWriter] = [:]) {
        self.cardMapper = cardMapper
        self.settings = settings
    }

    public static func matches(_ lhs: ProviderConfig?, _ rhs: ProviderConfig?) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    public func applying(_ values: [String: String], to config: ProviderConfig) throws -> ProviderConfig {
        guard values.count <= 16 else { throw ProviderPluginError.invalidSnapshot("persist exceeds 16 keys") }
        var updated = config
        for (key, value) in values {
            guard key.utf8.count <= 64, value.utf8.count <= 256, let write = self.settings[key] else {
                throw ProviderPluginError.invalidSnapshot("persist contains an unapproved setting")
            }
            try write(value, &updated)
        }
        return updated
    }
}

/// Serializes CLI discoveries and reloads the file so another provider's settings are preserved.
public actor ProviderPluginConfigWriter {
    public static let shared = ProviderPluginConfigWriter()

    public func save(
        provider: UsageProvider,
        values: [String: String],
        expected: ProviderConfig?,
        store: CodexBarConfigStore) -> ProviderSettingsSaveOutcome
    {
        guard !Task.isCancelled else { return .stale }
        do {
            var config = try store.load() ?? .makeDefault()
            guard ProviderPluginResultPolicy.matches(config.providerConfig(for: provider.instanceID), expected)
            else { return .stale }
            let original = expected ?? ProviderConfig(id: provider.instanceID)
            let updated = try ProviderDescriptorRegistry.descriptor(for: provider).pluginResultPolicy
                .applying(values, to: original)
            guard !ProviderPluginResultPolicy.matches(updated, original) else { return .unchanged }
            config.setProviderConfig(updated)
            try store.save(config)
            return .saved
        } catch {
            return .failed
        }
    }
}

extension ProviderPluginSnapshotMapper {
    static func mapResult(
        _ value: any ProviderPluginValue,
        provider: ProviderInstanceID,
        now: Date,
        allowsProviderExtensions: Bool = true,
        percentPolicy: ProviderPluginPercentPolicy = .clamp) throws -> ProviderPluginResult
    {
        let keys = try self.objectKeys(value, path: "result")
        let envelope = keys.contains("usage")
        guard envelope else {
            return try ProviderPluginResult(
                usage: self.map(value, provider: provider, now: now, percentPolicy: percentPolicy),
                sourceLabel: nil,
                persist: [:])
        }
        try self.validateKeys(keys, allowed: ["usage", "sourceLabel", "card", "persist"], path: "result")
        let policy = (allowsProviderExtensions ? provider.firstPartyProvider : nil).map {
            ProviderDescriptorRegistry.descriptor(for: $0).pluginResultPolicy
        } ?? ProviderPluginResultPolicy()
        guard let rawUsage = value.property("usage") else {
            throw ProviderPluginError.invalidSnapshot("usage is required")
        }
        var usage = try self.map(rawUsage, provider: provider, now: now, percentPolicy: percentPolicy)
        var sourceLabel: String?
        if keys.contains("sourceLabel"), let label = value.property("sourceLabel") {
            sourceLabel = try self.resultString(label, path: "sourceLabel")
        }
        if keys.contains("card"), let card = value.property("card") {
            guard let map = policy.cardMapper else {
                throw ProviderPluginError.invalidSnapshot("card is not allowed for this provider")
            }
            usage = try map(card, usage, now)
        }
        var persist: [String: String] = [:]
        if keys.contains("persist"), let raw = value.property("persist") {
            let keys = try self.objectKeys(raw, path: "persist")
            guard keys.count <= 16 else { throw ProviderPluginError.invalidSnapshot("persist exceeds 16 keys") }
            for key in keys {
                guard let value = raw.property(key) else { continue }
                persist[key] = try self.resultString(value, path: "persist value")
            }
            _ = try policy.applying(persist, to: ProviderConfig(id: provider))
        }
        return ProviderPluginResult(usage: usage, sourceLabel: sourceLabel, persist: persist)
    }

    static func objectKeys(_ value: any ProviderPluginValue, path: String) throws -> Set<String> {
        guard value.isObject, !value.isArray, !value.isNull, !value.isDate else {
            throw ProviderPluginError.invalidSnapshot("\(path) must be an object")
        }
        return try Set(value.propertyNames())
    }

    static func validateKeys(_ keys: Set<String>, allowed: Set<String>, path: String) throws {
        guard keys.isSubset(of: allowed) else {
            throw ProviderPluginError.invalidSnapshot("\(path) contains unknown keys")
        }
    }

    static func object(_ value: any ProviderPluginValue, allowed: Set<String>, path: String) throws {
        try self.validateKeys(self.objectKeys(value, path: path), allowed: allowed, path: path)
    }

    static func boundedArrayCount(_ value: any ProviderPluginValue, maximum: Int, path: String) throws -> Int {
        guard value.isArray, let length = value.property("length")?.doubleValue(),
              length.isFinite, length >= 0, length <= Double(maximum), length.rounded() == length
        else { throw ProviderPluginError.invalidSnapshot("\(path) exceeds \(maximum) entries") }
        return Int(length)
    }

    static func resultString(_ value: any ProviderPluginValue, path: String) throws -> String {
        guard value.isString else { throw ProviderPluginError.invalidSnapshot("\(path) must be a string") }
        let text = value.stringValue()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 256,
              text.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw ProviderPluginError.invalidSnapshot("\(path) must contain 1-256 bytes without control characters")
        }
        return text
    }
}
