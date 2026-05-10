import CodexBarCore
import Foundation

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
                ? String(format: L("jetbrains_detected_select"), ideNames)
                : String(format: L("jetbrains_detected_generate"), ideNames)
            self.presentLoginAlert(
                title: L("JetBrains AI is ready"),
                message: message)
        }
    }
}
