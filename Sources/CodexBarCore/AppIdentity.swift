import Foundation

public enum ReleaseConfig {
    public static let githubOwner = "ShawnRn"
    public static let githubRepo = "CodexBar"
    public static let appcastURL = "https://raw.githubusercontent.com/ShawnRn/CodexBar/main/appcast.xml"
    public static let releasesURL = "https://github.com/ShawnRn/CodexBar/releases"
    public static let repositoryURL = "https://github.com/ShawnRn/CodexBar"
    public static let publicEDKey = "pzuYYTba0w3WDEVJrFkq8DahiqHhozXlz501nZbLhT8="
    public static let changelogURL = "\(repositoryURL)/blob/main/CHANGELOG.md"
    public static let providerGuideURL = "\(repositoryURL)/blob/main/docs/provider.md"
    public static let providersURL = "\(repositoryURL)/blob/main/docs/providers.md"
    public static let cliURL = "\(repositoryURL)/blob/main/docs/cli.md"
    public static let licenseURL = "\(repositoryURL)/blob/main/LICENSE"

    public static func releaseAssetURL(tag: String, assetName: String) -> String {
        "\(self.releasesURL)/download/\(tag)/\(assetName)"
    }
}

public enum AppIdentity {
    public static let appName = "CodexBar"
    public static let bundleID = "com.shawnrn.codexbar"
    public static let debugBundleID = "com.shawnrn.codexbar.debug"
    public static let legacyBundleID = "com.steipete.codexbar"
    public static let legacyDebugBundleID = "com.steipete.codexbar.debug"
    public static let appGroupID = "group.com.shawnrn.codexbar"
    public static let debugAppGroupID = "group.com.shawnrn.codexbar.debug"
    public static let legacyAppGroupID = "group.com.steipete.codexbar"
    public static let legacyDebugAppGroupID = "group.com.steipete.codexbar.debug"
    public static let keychainCacheService = "com.shawnrn.codexbar.cache"
    public static let legacyKeychainCacheService = "com.steipete.codexbar.cache"
    public static let appSupportDirectoryName = "com.shawnrn.codexbar"
    public static let legacyAppSupportDirectoryName = "com.steipete.codexbar"
    public static let logSubsystem = "com.shawnrn.codexbar"

    public static func isDebugBundle(_ bundleID: String?) -> Bool {
        switch bundleID {
        case self.debugBundleID, self.legacyDebugBundleID:
            true
        default:
            bundleID?.contains(".debug") == true
        }
    }

    public static func preferredBundleID(isDebug: Bool) -> String {
        isDebug ? self.debugBundleID : self.bundleID
    }

    public static func preferredAppGroupID(isDebug: Bool) -> String {
        isDebug ? self.debugAppGroupID : self.appGroupID
    }

    public static func preferredAppGroupID(for bundleID: String?) -> String {
        self.preferredAppGroupID(isDebug: self.isDebugBundle(bundleID))
    }

    public static func legacyBundleIDs(isDebug: Bool) -> [String] {
        isDebug ? [self.legacyDebugBundleID] : [self.legacyBundleID]
    }

    public static func legacyAppGroupIDs(isDebug: Bool) -> [String] {
        isDebug ? [self.legacyDebugAppGroupID] : [self.legacyAppGroupID]
    }

    public static func appGroupIDs(for bundleID: String?) -> [String] {
        let isDebug = self.isDebugBundle(bundleID)
        return [self.preferredAppGroupID(isDebug: isDebug)] + self.legacyAppGroupIDs(isDebug: isDebug)
    }

    public static func userDefaultsDomains(for bundleID: String?) -> [String] {
        let isDebug = self.isDebugBundle(bundleID)
        return [self.preferredBundleID(isDebug: isDebug)] + self.legacyBundleIDs(isDebug: isDebug)
    }

    public static func keychainCacheServices() -> [String] {
        [self.keychainCacheService, self.legacyKeychainCacheService]
    }

    public static func applicationSupportDirectories() -> [String] {
        [self.appSupportDirectoryName, self.legacyAppSupportDirectoryName]
    }
}

public enum AppIdentityMigration {
    public static func migrateUserDefaults(bundleID: String? = Bundle.main.bundleIdentifier) {
        let domains = AppIdentity.userDefaultsDomains(for: bundleID)
        guard let currentDomain = domains.first else { return }

        let defaults = UserDefaults.standard
        for legacyDomain in domains.dropFirst() {
            guard let persisted = defaults.persistentDomain(forName: legacyDomain), !persisted.isEmpty else { continue }
            for (key, value) in persisted where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            if defaults.persistentDomain(forName: currentDomain) == nil {
                defaults.setPersistentDomain(persisted, forName: currentDomain)
            }
        }
    }

    public static func migrateSharedDefaults(bundleID: String? = Bundle.main.bundleIdentifier) {
        let groupIDs = AppIdentity.appGroupIDs(for: bundleID)
        guard let currentGroupID = groupIDs.first,
              let currentDefaults = UserDefaults(suiteName: currentGroupID) else { return }

        for legacyGroupID in groupIDs.dropFirst() {
            guard let legacyDefaults = UserDefaults(suiteName: legacyGroupID) else { continue }
            let dictionary = legacyDefaults.dictionaryRepresentation()
            guard !dictionary.isEmpty else { continue }
            for (key, value) in dictionary where currentDefaults.object(forKey: key) == nil {
                currentDefaults.set(value, forKey: key)
            }
        }
    }
}
