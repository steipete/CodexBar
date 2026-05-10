import Foundation
import Testing
@testable import CodexBarCore

struct AppGroupSupportTests {
    @Test
    func `app group identifiers use resolved team-prefixed release and debug variants`() {
        #expect(
            AppGroupSupport.currentGroupID(teamID: "Y5PE65HELJ", bundleID: "com.steipete.codexbar")
                == "Y5PE65HELJ.com.steipete.codexbar")
        #expect(
            AppGroupSupport.currentGroupID(teamID: "ABCDE12345", bundleID: "com.steipete.codexbar.debug")
                == "ABCDE12345.com.steipete.codexbar.debug")
        #expect(
            AppGroupSupport.legacyGroupID(for: "com.steipete.codexbar")
                == "group.com.steipete.codexbar")
        #expect(
            AppGroupSupport.legacyGroupID(for: "com.steipete.codexbar.debug")
                == "group.com.steipete.codexbar.debug")
    }

    @Test
    func `resolved team id falls back to plist and then default`() {
        #expect(
            AppGroupSupport.resolvedTeamID(
                infoDictionaryOverride: [AppGroupSupport.teamIDInfoKey: "ABCDE12345"],
                bundleURLOverride: nil) == "ABCDE12345")
        #expect(
            AppGroupSupport.resolvedTeamID(
                infoDictionaryOverride: nil,
                bundleURLOverride: nil) == AppGroupSupport.defaultTeamID)
    }

    @Test
    func `legacy migration copies snapshot once`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let standardSuite = "AppGroupSupportTests-standard-\(UUID().uuidString)"
        let currentSuite = "AppGroupSupportTests-current-\(UUID().uuidString)"
        let legacySuite = "AppGroupSupportTests-legacy-\(UUID().uuidString)"

        let standardDefaults = try #require(UserDefaults(suiteName: standardSuite))
        let currentDefaults = try #require(UserDefaults(suiteName: currentSuite))
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuite))
        standardDefaults.removePersistentDomain(forName: standardSuite)
        currentDefaults.removePersistentDomain(forName: currentSuite)
        legacyDefaults.removePersistentDomain(forName: legacySuite)

        legacyDefaults.set(true, forKey: "debugDisableKeychainAccess")
        legacyDefaults.set(UsageProvider.cursor.rawValue, forKey: "widgetSelectedProvider")

        let legacySnapshotURL = root.appendingPathComponent(
            "legacy/widget-snapshot.json",
            isDirectory: false)
        try fileManager.createDirectory(
            at: legacySnapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("legacy-snapshot".utf8).write(to: legacySnapshotURL)

        let currentSnapshotURL = root.appendingPathComponent("current/widget-snapshot.json", isDirectory: false)
        let result = AppGroupSupport.migrateLegacyDataIfNeeded(
            bundleID: "com.steipete.codexbar",
            standardDefaults: standardDefaults,
            currentDefaultsOverride: currentDefaults,
            legacyDefaultsOverride: legacyDefaults,
            currentSnapshotURLOverride: currentSnapshotURL,
            legacySnapshotURLOverride: legacySnapshotURL)

        #expect(result.status == .migrated)
        #expect(result.copiedSnapshot)
        #expect(result.copiedDefaults == 2)
        #expect(currentDefaults.bool(forKey: "debugDisableKeychainAccess"))
        #expect(currentDefaults.string(forKey: "widgetSelectedProvider") == UsageProvider.cursor.rawValue)
        #expect(fileManager.fileExists(atPath: currentSnapshotURL.path))
        #expect(
            standardDefaults.integer(forKey: AppGroupSupport.migrationVersionKey)
                == AppGroupSupport.migrationVersion)

        let secondResult = AppGroupSupport.migrateLegacyDataIfNeeded(
            bundleID: "com.steipete.codexbar",
            standardDefaults: standardDefaults,
            currentDefaultsOverride: currentDefaults,
            legacyDefaultsOverride: legacyDefaults,
            currentSnapshotURLOverride: currentSnapshotURL,
            legacySnapshotURLOverride: legacySnapshotURL)
        #expect(secondResult.status == .alreadyCompleted)
    }

    @Test
    func `legacy migration preserves existing target shared defaults`() throws {
        let standardSuite = "AppGroupSupportTests-standard-existing-\(UUID().uuidString)"
        let currentSuite = "AppGroupSupportTests-current-existing-\(UUID().uuidString)"
        let legacySuite = "AppGroupSupportTests-legacy-existing-\(UUID().uuidString)"

        let standardDefaults = try #require(UserDefaults(suiteName: standardSuite))
        let currentDefaults = try #require(UserDefaults(suiteName: currentSuite))
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuite))
        standardDefaults.removePersistentDomain(forName: standardSuite)
        currentDefaults.removePersistentDomain(forName: currentSuite)
        legacyDefaults.removePersistentDomain(forName: legacySuite)

        currentDefaults.set(false, forKey: "debugDisableKeychainAccess")
        currentDefaults.set(UsageProvider.codex.rawValue, forKey: "widgetSelectedProvider")
        legacyDefaults.set(true, forKey: "debugDisableKeychainAccess")
        legacyDefaults.set(UsageProvider.cursor.rawValue, forKey: "widgetSelectedProvider")

        let result = AppGroupSupport.migrateLegacyDataIfNeeded(
            bundleID: "com.steipete.codexbar",
            standardDefaults: standardDefaults,
            currentDefaultsOverride: currentDefaults,
            legacyDefaultsOverride: legacyDefaults)

        #expect(result.status == .noChangesNeeded)
        #expect(result.copiedDefaults == 0)
        #expect(!currentDefaults.bool(forKey: "debugDisableKeychainAccess"))
        #expect(currentDefaults.string(forKey: "widgetSelectedProvider") == UsageProvider.codex.rawValue)
    }
}
