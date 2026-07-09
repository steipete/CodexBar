extension StatusItemController {
    func widgetDisplaySettingsSignature() -> String {
        [
            "enabled=\(self.store.enabledProvidersForDisplay().map(\.rawValue).joined(separator: ","))",
            "showUsed=\(self.settings.usageBarsShowUsed ? "1" : "0")",
            "optional=\(self.settings.showOptionalCreditsAndExtraUsage ? "1" : "0")",
        ].joined(separator: "|")
    }

    func persistWidgetSnapshotIfWidgetDisplaySettingsChanged() {
        let signature = self.widgetDisplaySettingsSignature()
        guard signature != self.lastWidgetDisplaySettingsSignature else { return }
        self.lastWidgetDisplaySettingsSignature = signature
        self.store.persistWidgetSnapshot(reason: "settings-display")
    }
}
