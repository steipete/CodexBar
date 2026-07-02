import Foundation

public struct CodexBarPortablePreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int?
    public var refreshFrequency: String?
    public var usageBarsShowUsed: Bool?
    public var resetTimesShowAbsolute: Bool?
    public var providerChangelogLinksEnabled: Bool?
    public var menuBarDisplayMode: String?
    public var menuBarShowsBrandIconWithPercent: Bool?
    public var menuBarHidesCritters: Bool?
    public var menuBarShowsHighestUsage: Bool?
    public var mergeIcons: Bool?
    public var switcherShowsIcons: Bool?
    public var mergedOverviewSelectedProviders: [String]?
    public var providersSortedAlphabetically: Bool?
    public var appLanguage: String?
    public var randomBlinkEnabled: Bool?
    public var confettiOnWeeklyLimitResetsEnabled: Bool?

    public init(
        version: Int = Self.currentVersion,
        refreshFrequency: String? = nil,
        usageBarsShowUsed: Bool? = nil,
        resetTimesShowAbsolute: Bool? = nil,
        providerChangelogLinksEnabled: Bool? = nil,
        menuBarDisplayMode: String? = nil,
        menuBarShowsBrandIconWithPercent: Bool? = nil,
        menuBarHidesCritters: Bool? = nil,
        menuBarShowsHighestUsage: Bool? = nil,
        mergeIcons: Bool? = nil,
        switcherShowsIcons: Bool? = nil,
        mergedOverviewSelectedProviders: [String]? = nil,
        providersSortedAlphabetically: Bool? = nil,
        appLanguage: String? = nil,
        randomBlinkEnabled: Bool? = nil,
        confettiOnWeeklyLimitResetsEnabled: Bool? = nil)
    {
        self.version = version
        self.refreshFrequency = refreshFrequency
        self.usageBarsShowUsed = usageBarsShowUsed
        self.resetTimesShowAbsolute = resetTimesShowAbsolute
        self.providerChangelogLinksEnabled = providerChangelogLinksEnabled
        self.menuBarDisplayMode = menuBarDisplayMode
        self.menuBarShowsBrandIconWithPercent = menuBarShowsBrandIconWithPercent
        self.menuBarHidesCritters = menuBarHidesCritters
        self.menuBarShowsHighestUsage = menuBarShowsHighestUsage
        self.mergeIcons = mergeIcons
        self.switcherShowsIcons = switcherShowsIcons
        self.mergedOverviewSelectedProviders = mergedOverviewSelectedProviders
        self.providersSortedAlphabetically = providersSortedAlphabetically
        self.appLanguage = appLanguage
        self.randomBlinkEnabled = randomBlinkEnabled
        self.confettiOnWeeklyLimitResetsEnabled = confettiOnWeeklyLimitResetsEnabled
    }

    /// Explicit portable values win; omitted keys preserve the device's existing defaults state.
    public func resolved(over fallback: Self) -> Self {
        let portable = self.normalized()
        return Self(
            refreshFrequency: portable.refreshFrequency ?? fallback.refreshFrequency,
            usageBarsShowUsed: portable.usageBarsShowUsed ?? fallback.usageBarsShowUsed,
            resetTimesShowAbsolute: portable.resetTimesShowAbsolute ?? fallback.resetTimesShowAbsolute,
            providerChangelogLinksEnabled: portable.providerChangelogLinksEnabled ?? fallback
                .providerChangelogLinksEnabled,
            menuBarDisplayMode: portable.menuBarDisplayMode ?? fallback.menuBarDisplayMode,
            menuBarShowsBrandIconWithPercent: portable.menuBarShowsBrandIconWithPercent ?? fallback
                .menuBarShowsBrandIconWithPercent,
            menuBarHidesCritters: portable.menuBarHidesCritters ?? fallback.menuBarHidesCritters,
            menuBarShowsHighestUsage: portable.menuBarShowsHighestUsage ?? fallback.menuBarShowsHighestUsage,
            mergeIcons: portable.mergeIcons ?? fallback.mergeIcons,
            switcherShowsIcons: portable.switcherShowsIcons ?? fallback.switcherShowsIcons,
            mergedOverviewSelectedProviders: portable.mergedOverviewSelectedProviders ?? fallback
                .mergedOverviewSelectedProviders,
            providersSortedAlphabetically: portable.providersSortedAlphabetically ?? fallback
                .providersSortedAlphabetically,
            appLanguage: portable.appLanguage ?? fallback.appLanguage,
            randomBlinkEnabled: portable.randomBlinkEnabled ?? fallback.randomBlinkEnabled,
            confettiOnWeeklyLimitResetsEnabled: portable.confettiOnWeeklyLimitResetsEnabled ?? fallback
                .confettiOnWeeklyLimitResetsEnabled)
    }

    public func normalized() -> Self {
        var normalized = self
        normalized.version = Self.currentVersion
        normalized.refreshFrequency = Self.allowed(
            self.refreshFrequency,
            values: ["manual", "oneMinute", "twoMinutes", "fiveMinutes", "fifteenMinutes", "thirtyMinutes"])
        normalized.menuBarDisplayMode = Self.allowed(
            self.menuBarDisplayMode,
            values: ["percent", "pace", "both", "resetTime"])
        normalized.appLanguage = Self.normalizedLanguage(self.appLanguage)
        normalized.mergedOverviewSelectedProviders = self.mergedOverviewSelectedProviders.map { providers in
            var seen: Set<String> = []
            return providers.compactMap { raw -> String? in
                guard let value = Self.nonempty(raw), seen.insert(value).inserted else { return nil }
                return value
            }
        }
        return normalized
    }

    private static func nonempty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func allowed(_ raw: String?, values: Set<String>) -> String? {
        guard let value = nonempty(raw), values.contains(value) else { return nil }
        return value
    }

    private static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.isEmpty { return "" }
        return Self.allowed(raw, values: [
            "ar", "ca", "de", "en", "es", "fa", "fr", "id", "it", "ja", "ko", "nl", "pl", "pt-BR", "sv",
            "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
        ])
    }
}

public enum CodexBarPortablePreferencesStoreError: LocalizedError {
    case decodeFailed(String)
    case encodeFailed(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .decodeFailed(details):
            "Failed to decode CodexBar portable preferences: \(details)"
        case let .encodeFailed(details):
            "Failed to encode CodexBar portable preferences: \(details)"
        case let .unsupportedVersion(version):
            "CodexBar portable preferences version \(version) is newer than this app supports."
        }
    }
}

public struct CodexBarPortablePreferencesStore: @unchecked Sendable {
    public static let pathEnvironmentKey = "CODEXBAR_PREFERENCES"

    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> CodexBarPortablePreferences? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return nil }
        let data = try Data(contentsOf: self.fileURL)
        do {
            let decoded = try JSONDecoder().decode(CodexBarPortablePreferences.self, from: data)
            if let version = decoded.version, version > CodexBarPortablePreferences.currentVersion {
                throw CodexBarPortablePreferencesStoreError.unsupportedVersion(version)
            }
            return decoded.normalized()
        } catch let error as CodexBarPortablePreferencesStoreError {
            throw error
        } catch {
            throw CodexBarPortablePreferencesStoreError.decodeFailed(error.localizedDescription)
        }
    }

    public func save(_ preferences: CodexBarPortablePreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(preferences.normalized())
        } catch {
            throw CodexBarPortablePreferencesStoreError.encodeFailed(error.localizedDescription)
        }

        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: self.fileURL, options: [.atomic])
        #if os(macOS) || os(Linux)
        try self.fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: self.fileURL.path)
        #endif
    }

    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL? = nil) -> URL
    {
        if let override = environment[self.pathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }

        let configURL = configURL ?? CodexBarConfigStore.defaultURL(environment: environment)
        return configURL.deletingLastPathComponent().appendingPathComponent("preferences.json")
    }
}
