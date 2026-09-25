import CodexBarCore
import Foundation

extension SettingsStore {
    func exportPreferences() throws -> PreferencesDocument {
        var document = PreferencesDocument()
        try document.include(self.syncedPreferences)
        try document.set("mergeIcons", self.mergeIcons)
        try document.set("mergeIconsStacked", self.mergeIconsStacked)
        try document.set("switcherShowsIcons", self.switcherShowsIcons)
        try document.set("mergedOverviewLayout", self.mergedOverviewLayout.rawValue)
        if self.userDefaults.object(forKey: "mergedOverviewSelectedProviders") != nil {
            let active = self.orderedProviders().filter { self.providerEnablement[$0] ?? false }
                .compactMap(\.firstPartyProvider)
            try document.set(
                "mergedOverviewSelectedProviders",
                self.resolvedMergedOverviewProviders(activeProviders: active)
                    .map(\.rawValue))
        }
        try document.set("switcherShortcuts", self.providerSwitcherShortcuts)
        return document
    }

    func importPreferences(_ document: PreferencesDocument) throws {
        try document.validate()
        let synced = try document.applying(to: self.syncedPreferences)
        // Use the normal setters. CloudKit alone owns its incoming-record echo-suppression baseline.
        let consent = self.adaptiveActivityScanConsent
        self.applySyncedPreferences(synced)
        if self.adaptiveActivityScanConsent != consent { self.adaptiveActivityScanConsent = consent }
        if let value: Bool = try document.value("mergeIcons") { self.mergeIcons = value }
        if let value: Bool = try document.value("mergeIconsStacked") { self.mergeIconsStacked = value }
        if let value: Bool = try document.value("switcherShowsIcons") { self.switcherShowsIcons = value }
        if let value: String = try document.value("mergedOverviewLayout"),
           let layout = MergedOverviewLayout(rawValue: value)
        {
            self.mergedOverviewLayout = layout
        }
        if let value: [String] = try document.value("mergedOverviewSelectedProviders") {
            self.mergedOverviewSelectedProviders = value.compactMap(UsageProvider.init(rawValue:))
            let active = self.orderedProviders().filter { self.providerEnablement[$0] ?? false }
                .compactMap(\.firstPartyProvider)
            self.userDefaults.set(
                active.map(\.rawValue).sorted(),
                forKey: Self.mergedOverviewSelectionEditedActiveProvidersKey)
        }
        if let value: [String: String] = try document.value("switcherShortcuts") {
            try self.setProviderSwitcherShortcuts(value)
        }
    }

    func setProviderSwitcherShortcuts(_ shortcuts: [String: String]) throws {
        let validated = try ProviderSwitcherShortcuts.validated(shortcuts)
        self.providerSwitcherShortcuts = validated
        self.userDefaults.set(validated, forKey: "switcherShortcuts")
    }

    func consumePendingPreferencesImport() {
        self.userDefaults.synchronize()
        guard let data = self.userDefaults.data(forKey: PreferencesDocument.pendingImportKey) else { return }
        do {
            try self.importPreferences(PreferencesDocument(data: data))
            if self.userDefaults.data(forKey: PreferencesDocument.pendingImportKey) == data {
                self.userDefaults.removeObject(forKey: PreferencesDocument.pendingImportKey)
                self.userDefaults.synchronize()
            }
        } catch {
            CodexBarLog.logger(LogCategories.settings).error("Could not import portable preferences: \(error)")
        }
    }
}
