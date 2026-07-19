import AppKit
import CodexBarCore
import Foundation

@MainActor
extension StatusItemController {
    func runVertexAILoginFlow() async {
        // Show alert with instructions
        let alert = NSAlert()
        alert.messageText = L("Vertex AI Login")
        alert.informativeText = L("vertex_ai_login_instructions")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("Open Terminal"))
        alert.addButton(withTitle: L("Cancel"))

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            self.openTerminal(
                command: "gcloud auth application-default login --scopes=openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/cloud-platform")
        }

        // Refresh after user may have logged in
        self.loginPhase = .idle
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await self.store.refresh()
        }
    }
}
