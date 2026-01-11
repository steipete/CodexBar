import CodexBarCore

@MainActor
extension StatusItemController {
    func runJetBrainsLoginFlow() async {
        self.loginPhase = .idle
        let detectedIDEs = JetBrainsIDEDetector.detectInstalledIDEs()
        if detectedIDEs.isEmpty {
            self.presentLoginAlert(
                title: "No JetBrains IDE detected",
                message: "Install a JetBrains IDE with AI Assistant enabled, then refresh CodexBar. Alternatively, set a custom path in Settings.")
        } else {
            let ideNames = detectedIDEs.prefix(3).map(\.displayName).joined(separator: ", ")
            self.presentLoginAlert(
                title: "JetBrains AI is ready",
                message: "Detected: \(ideNames). Select your preferred IDE in Settings, then refresh CodexBar.")
        }
    }
}
