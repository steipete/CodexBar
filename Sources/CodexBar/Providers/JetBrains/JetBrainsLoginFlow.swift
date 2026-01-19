import CodexBarCore

@MainActor
extension StatusItemController {
    func runJetBrainsLoginFlow() async {
        self.loginPhase = .idle
        let detectedIDEs = JetBrainsIDEDetector.detectInstalledIDEs(includeMissingQuota: true)
        if detectedIDEs.isEmpty {
            let message = [
                "Install a JetBrains IDE with AI Assistant enabled, then refresh CodexBar.",
                "Alternatively, set a custom path in Settings.",
            ].joined(separator: " ")
            self.presentLoginAlert(
                title: "No JetBrains IDE detected",
                message: message)
        } else {
            let ideNames = detectedIDEs.prefix(3).map(\.displayName).joined(separator: ", ")
            let hasQuotaFile = !JetBrainsIDEDetector.detectInstalledIDEs().isEmpty
            let message = hasQuotaFile
                ? "Detected: \(ideNames). Select your preferred IDE in Settings, then refresh CodexBar."
                : "Detected: \(ideNames). Use AI Assistant once to generate quota data, then refresh CodexBar."
            self.presentLoginAlert(
                title: "JetBrains AI is ready",
                message: message)
        }
    }
}
