import CodexBarCore

@MainActor
extension StatusItemController {
    func runJetBrainsLoginFlow() async {
        self.loginPhase = .idle
        let detectedIDEs = JetBrainsIDEDetector.detectInstalledIDEs(includeMissingQuota: true)
        if detectedIDEs.isEmpty {
            let message = L10n.tr(
                "Install a JetBrains IDE with AI Assistant enabled, then refresh CodexBar. " +
                    "Alternatively, set a custom path in Settings.")
            self.presentLoginAlert(
                title: L10n.tr("No JetBrains IDE detected"),
                message: message)
        } else {
            let ideNames = detectedIDEs.prefix(3).map(\.displayName).joined(separator: ", ")
            let hasQuotaFile = !JetBrainsIDEDetector.detectInstalledIDEs().isEmpty
            let message = hasQuotaFile
                ? L10n.format(
                    "Detected: %@. Select your preferred IDE in Settings, then refresh CodexBar.",
                    ideNames)
                : L10n.format(
                    "Detected: %@. Use AI Assistant once to generate quota data, then refresh CodexBar.",
                    ideNames)
            self.presentLoginAlert(
                title: L10n.tr("JetBrains AI is ready"),
                message: message)
        }
    }
}
