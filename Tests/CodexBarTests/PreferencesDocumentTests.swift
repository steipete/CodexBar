import AppKit
import CodexBarCore
import Commander
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct PreferencesDocumentTests {
    private func store(_ suffix: String, defaults: UserDefaults = InMemoryUserDefaults()) -> SettingsStore {
        testSettingsStore(suiteName: "PreferencesDocumentTests-\(suffix)", userDefaults: defaults)
    }

    @Test
    func `portable preferences round trip uses existing defaults without touching config`() throws {
        let source = self.store("source")
        source.refreshFrequency = .fiveMinutes
        source.hidePersonalInfo = true
        source.mergeIcons = false
        source.weeklyProgressWorkDays = nil
        try source.setProviderSwitcherShortcuts(["select2": "alt+cmd+2", "next": "shift+right"])
        let target = self.store("target")
        target.weeklyProgressWorkDays = 4
        let configBefore = try target.configSnapshot.encodedData()
        let document = try PreferencesDocument(data: source.exportPreferences().encoded())
        try target.importPreferences(document)
        #expect(target.refreshFrequency == .fiveMinutes)
        #expect(target.hidePersonalInfo)
        #expect(!target.mergeIcons)
        #expect(target.weeklyProgressWorkDays == nil)
        #expect(target.providerSwitcherShortcuts["select2"] == "alt+cmd+2")
        #expect(try target.configSnapshot.encodedData() == configBefore)
        #expect(try target.exportPreferences().encoded() == source.exportPreferences().encoded())
    }

    @Test
    func `missing keys preserve existing preferences and legacy defaults`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set("twoMinutes", forKey: "refreshFrequency")
        defaults.set(true, forKey: "mergeIconsStacked")
        let settings = self.store("migration", defaults: defaults)
        let document =
            try PreferencesDocument(data: Data(#"{"version":1,"preferences":{"hidePersonalInfo":true}}"#.utf8))
        try settings.importPreferences(document)
        #expect(settings.refreshFrequency == .twoMinutes)
        #expect(settings.mergeIconsStacked)
        #expect(settings.providerSwitcherShortcuts == ProviderSwitcherShortcuts.defaults)
        #expect(settings.hidePersonalInfo)
    }

    @Test
    func `allowlist excludes secrets paths login consent and device identity`() throws {
        let defaults = InMemoryUserDefaults()
        for key in [
            "apiKey",
            "hooks",
            "launchAtLogin",
            "terminalApp",
            "jetbrainsIDEBasePath",
            "adaptiveActivityScanConsent",
            "iCloudSyncDeviceID",
            "iCloudSyncEnabled",
            "debugMenuEnabled",
        ] {
            defaults.set("PRIVATE-SENTINEL", forKey: key)
            let json = "{\"version\":1,\"preferences\":{\"\(key)\":\"PRIVATE-SENTINEL\"}}"
            #expect(throws: (any Error).self) { try PreferencesDocument(data: Data(json.utf8)) }
        }
        let json = try #require(String(data: PreferencesDocument(defaults: defaults).encoded(), encoding: .utf8))
        #expect(!json.contains("PRIVATE-SENTINEL"))
        #expect(!json.contains("launchAtLogin"))
    }

    @Test(arguments: [
        #"{"version":2,"preferences":{}}"#,
        #"{"version":1,"preferences":{"hidePersonalInfo":"true"}}"#,
        #"{"version":1,"preferences":{"weeklyProgressWorkDays":9}}"#,
        #"{"version":1,"preferences":{"refreshFrequency":"tomorrow"}}"#,
        #"{"version":1,"preferences":{"switcherShortcuts":{"next":"left"}}}"#,
    ])
    func `invalid documents reject before any setters`(_ json: String) throws {
        #expect(throws: (any Error).self) { try PreferencesDocument(data: Data(json.utf8)) }
    }

    @Test
    func `queued CLI imports merge and are consumed through setters`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = self.store("queued", defaults: defaults)
        var first = PreferencesDocument()
        try first.set("hidePersonalInfo", true)
        try first.queueImport(in: defaults)
        var second = PreferencesDocument()
        try second.set("mergeIcons", false)
        try second.queueImport(in: defaults)
        #expect(!settings.hidePersonalInfo)
        let pendingExport = try PreferencesDocument(defaults: defaults)
        #expect(try pendingExport.value("hidePersonalInfo", as: Bool.self) == true)
        settings.consumePendingPreferencesImport()
        #expect(settings.hidePersonalInfo)
        #expect(!settings.mergeIcons)
        #expect(defaults.data(forKey: PreferencesDocument.pendingImportKey) == nil)
        #expect(defaults.bool(forKey: "hidePersonalInfo"))
    }

    @Test
    func `overview import marks the selection edited for local active providers`() throws {
        let settings = self.store("overview")
        let active = settings.orderedProviders().filter { settings.providerEnablement[$0] ?? false }
            .compactMap(\.firstPartyProvider)
        try #require(!active.isEmpty)
        var document = PreferencesDocument()
        try document.set("mergedOverviewSelectedProviders", [String]())
        try settings.importPreferences(document)
        #expect(settings.resolvedMergedOverviewProviders(activeProviders: active).isEmpty)
        #expect(settings.userDefaults.stringArray(forKey: SettingsStore.mergedOverviewSelectionEditedActiveProvidersKey)
            == active.map(\.rawValue).sorted())
    }

    @Test
    func `imports preserve activity scan consent`() throws {
        let settings = self.store("consent")
        settings.adaptiveActivityScanConsent = .declined
        var document = PreferencesDocument()
        try document.set("refreshFrequency", "adaptiveAgentAware")
        try settings.importPreferences(document)
        #expect(settings.adaptiveActivityScanConsent == .declined)
        #expect(!settings.adaptiveActivityScanningEnabled)
    }

    @Test
    func `CLI preferences options expose file and alternate defaults domain`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigPreferencesOptions()).flattened())
        let parsed = try parser.parse(arguments: [
            "--file",
            "/synthetic/preferences.json",
            "--defaults-domain",
            "fixture",
            "--json",
        ])
        #expect(parsed.options["file"] == ["/synthetic/preferences.json"])
        #expect(parsed.options["defaultsDomain"] == ["fixture"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }
}

struct ProviderSwitcherShortcutsTests {
    @Test
    func `defaults and customized combinations resolve consistently`() throws {
        let defaults = ProviderSwitcherShortcuts.defaults
        #expect(ProviderSwitcherShortcuts.action(key: "2", modifiers: ["cmd"], mapping: defaults) == "select2")
        #expect(ProviderSwitcherShortcuts.action(key: "right", modifiers: [], mapping: defaults) == "next")
        let custom = try ProviderSwitcherShortcuts.validated(["select2": "CMD+alt+2", "next": "shift+right"])
        #expect(custom["select2"] == "alt+cmd+2")
        #expect(ProviderSwitcherShortcuts.action(key: "2", modifiers: ["alt", "cmd"], mapping: custom) == "select2")
        #expect(ProviderSwitcherShortcuts.action(key: "2", modifiers: ["cmd"], mapping: custom) == nil)
        #expect(ProviderSwitcherShortcuts.action(key: "right", modifiers: ["shift"], mapping: custom) == "next")
    }

    @Test(arguments: [
        "cmd+r",
        "cmd+,",
        "cmd+q",
        "cmd+w",
        "cmd+h",
        "cmd+m",
        "alt+cmd+h",
        "escape",
        "shift+tab",
        "x",
        "shift+x",
        "cmd+cmd+2",
        "hyper+2",
        "cmd+",
    ])
    func `reserved or malformed combinations are rejected`(_ shortcut: String) {
        #expect(throws: (any Error).self) { try ProviderSwitcherShortcuts.validated(["next": shortcut]) }
    }

    @Test
    func `duplicates include default actions while disabled actions may repeat`() throws {
        #expect(throws: (any Error).self) { try ProviderSwitcherShortcuts.validated(["next": "left"]) }
        #expect(throws: (any Error).self) { try ProviderSwitcherShortcuts.validated(["select2": "cmd+1"]) }
        #expect(throws: (any Error).self) { try ProviderSwitcherShortcuts.validated(["unknown": "none"]) }
        let disabled = try ProviderSwitcherShortcuts.validated(["previous": "none", "next": "none"])
        #expect(disabled["previous"] == "none")
        #expect(disabled["next"] == "none")
    }

    @Test
    @MainActor
    func `shifted digit shortcuts match the unmodified key`() throws {
        let custom = try ProviderSwitcherShortcuts.validated(["select2": "shift+cmd+2"])
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "@",
            charactersIgnoringModifiers: "@",
            isARepeat: false,
            keyCode: 19))
        #expect(StatusItemMenu.providerSelectionIndex(for: event, mapping: custom) == 1)
    }

    @Test
    @MainActor
    func `both AppKit event helpers use custom mappings without live menus`() throws {
        let custom = try ProviderSwitcherShortcuts.validated(["select2": "alt+cmd+2", "next": "shift+right"])
        let selection = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "2",
            charactersIgnoringModifiers: "2",
            isARepeat: false,
            keyCode: 19))
        let next = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124))
        #expect(StatusItemMenu.providerSelectionIndex(for: selection, mapping: custom) == 1)
        #expect(StatusItemMenu.providerSelectionIndex(for: selection) == nil)
        #expect(StatusItemMenu.providerNavigationDirection(for: next, mapping: custom) == .next)
        #expect(StatusItemMenu.providerNavigationDirection(for: next) == nil)
    }
}
