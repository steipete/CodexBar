import CodexBarCore

@MainActor
extension StatusItemController {
    func runJetBrainsLoginFlow() async {
        self.loginPhase = .idle
        let detectedIDEs = JetBrainsIDEDetector.detectInstalledIDEs(includeMissingQuota: true)
        if detectedIDEs.isEmpty {
            let message = [
                AppStrings.tr("Install a JetBrains IDE with AI Assistant enabled, then refresh CodexBar."),
                AppStrings.tr("Alternatively, set a custom path in Settings."),
            ].joined(separator: " ")
            self.presentLoginAlert(
                title: AppStrings.tr("No JetBrains IDE detected"),
                message: message)
        } else {
            let ideNames = detectedIDEs.prefix(3).map(\.displayName).joined(separator: ", ")
            let hasQuotaFile = !JetBrainsIDEDetector.detectInstalledIDEs().isEmpty
            let message = hasQuotaFile
                ? AppStrings.fmt(
                    "Detected: %@. Select your preferred IDE in Settings, then refresh CodexBar.",
                    ideNames)
                : AppStrings.fmt(
                    "Detected: %@. Use AI Assistant once to generate quota data, then refresh CodexBar.",
                    ideNames)
            self.presentLoginAlert(
                title: AppStrings.tr("JetBrains AI is ready"),
                message: message)
        }
    }
}
