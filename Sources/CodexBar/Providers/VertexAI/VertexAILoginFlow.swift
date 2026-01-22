import AppKit
import CodexBarCore
import Foundation

@MainActor
extension StatusItemController {
    func runVertexAILoginFlow() async {
        // Show alert with instructions
        let alert = NSAlert()
        alert.messageText = "Vertex AI Login"
        alert.informativeText = """
        To use Vertex AI tracking, you need to authenticate with Google Cloud.

        1. Open Terminal
        2. Run: gcloud auth application-default login
        3. Follow the browser prompts to sign in
        4. Set your project: gcloud config set project PROJECT_ID

        Would you like to open Terminal now?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            Self.openTerminalWithGcloudCommand()
        }

        // Refresh after user may have logged in
        self.loginPhase = .idle
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await self.store.refresh()
        }
    }

    private static func openTerminalWithGcloudCommand() {
        let script = """
        tell application "Terminal"
            activate
            do script "gcloud auth application-default login --scopes=openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/cloud-platform"
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                CodexBarLog.logger(LogCategories.terminal).error(
                    "Failed to open Terminal",
                    metadata: ["error": String(describing: error)])
            }
        }
    }
}
