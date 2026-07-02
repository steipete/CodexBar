import CodexBarCore
import Foundation
import Testing

struct CodexBarPortablePreferencesTests {
    @Test
    func `explicit portable keys override defaults while omissions preserve them`() {
        let defaults = CodexBarPortablePreferences(
            refreshFrequency: "fiveMinutes",
            usageBarsShowUsed: false,
            mergeIcons: false,
            switcherShowsIcons: true,
            appLanguage: "en")
        let portable = CodexBarPortablePreferences(
            refreshFrequency: "manual",
            usageBarsShowUsed: true,
            mergeIcons: true)

        let resolved = portable.resolved(over: defaults)

        #expect(resolved.refreshFrequency == "manual")
        #expect(resolved.usageBarsShowUsed == true)
        #expect(resolved.mergeIcons == true)
        #expect(resolved.switcherShowsIcons == true)
        #expect(resolved.appLanguage == "en")
    }

    @Test
    func `invalid enum values fall back per key`() {
        let defaults = CodexBarPortablePreferences(
            refreshFrequency: "fiveMinutes",
            menuBarDisplayMode: "percent",
            appLanguage: "en")
        let portable = CodexBarPortablePreferences(
            refreshFrequency: "sometimes",
            menuBarDisplayMode: "huge",
            appLanguage: "klingon")

        let resolved = portable.resolved(over: defaults)

        #expect(resolved.refreshFrequency == "fiveMinutes")
        #expect(resolved.menuBarDisplayMode == "percent")
        #expect(resolved.appLanguage == "en")
    }

    @Test
    func `normalization keeps forward compatible provider ids and removes duplicates`() {
        let preferences = CodexBarPortablePreferences(
            refreshFrequency: "  fiveMinutes ",
            menuBarDisplayMode: " both ",
            mergedOverviewSelectedProviders: ["codex", "", "future-provider", "codex"],
            appLanguage: " en ")

        let normalized = preferences.normalized()

        #expect(normalized.version == CodexBarPortablePreferences.currentVersion)
        #expect(normalized.refreshFrequency == "fiveMinutes")
        #expect(normalized.menuBarDisplayMode == "both")
        #expect(normalized.mergedOverviewSelectedProviders == ["codex", "future-provider"])
        #expect(normalized.appLanguage == "en")
    }

    @Test
    func `encoded schema excludes secrets privacy controls and device local state`() throws {
        let data = try JSONEncoder().encode(CodexBarPortablePreferences(
            refreshFrequency: "fiveMinutes",
            usageBarsShowUsed: true,
            mergedOverviewSelectedProviders: ["codex", "claude"]))
        let json = try #require(String(data: data, encoding: .utf8))

        for excludedKey in [
            "apiKey",
            "cookieHeader",
            "hidePersonalInfo",
            "launchAtLogin",
            "selectedMenuProvider",
            "terminalApp",
            "tokenCostUsageEnabled",
        ] {
            #expect(!json.contains(excludedKey))
        }
    }

    @Test
    func `store stays opt in and round trips a sparse document`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarPortablePreferencesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("preferences.json")
        let store = CodexBarPortablePreferencesStore(fileURL: fileURL)

        #expect(try store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        let preferences = CodexBarPortablePreferences(
            usageBarsShowUsed: true,
            mergedOverviewSelectedProviders: ["codex", "claude"])
        try store.save(preferences)

        #expect(try store.load() == preferences)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }

    @Test
    func `empty document loads as no overrides`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarPortablePreferencesTests-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("preferences.json")
        try Data("{}".utf8).write(to: fileURL)
        let store = CodexBarPortablePreferencesStore(fileURL: fileURL)

        #expect(try store.load() == CodexBarPortablePreferences())
    }

    @Test
    func `store refuses a future schema version`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarPortablePreferencesTests-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("preferences.json")
        try Data("{\"version\": 99}".utf8).write(to: fileURL)
        let store = CodexBarPortablePreferencesStore(fileURL: fileURL)

        #expect(throws: CodexBarPortablePreferencesStoreError.self) {
            try store.load()
        }
    }

    @Test
    func `default path sits beside config and supports an explicit override`() {
        let configURL = URL(fileURLWithPath: "/tmp/codexbar/config.json")
        #expect(CodexBarPortablePreferencesStore.defaultURL(
            environment: [:],
            configURL: configURL).path == "/tmp/codexbar/preferences.json")

        #expect(CodexBarPortablePreferencesStore.defaultURL(
            environment: ["CODEXBAR_PREFERENCES": "/tmp/shared-codexbar.json"],
            configURL: configURL).path == "/tmp/shared-codexbar.json")
    }
}
