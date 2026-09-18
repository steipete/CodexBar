import AppKit
import Foundation

enum GrokLoginAlertPresentation {
    static func alertInfo(for result: CLILoginRunner.Result) -> CodexLoginAlertInfo? {
        switch result.outcome {
        case .success, .cancelled:
            return nil
        case .missingBinary:
            return CodexLoginAlertInfo(
                title: L("Grok CLI not found"),
                message: L("Install the Grok CLI (`grok`) and try again."))
        case let .launchFailed(message):
            return CodexLoginAlertInfo(title: L("Could not start grok login"), message: message)
        case .timedOut:
            return CodexLoginAlertInfo(
                title: L("Grok login timed out"),
                message: self.trimmedOutput(result.output))
        case let .failed(status):
            let statusLine = String(format: L("grok login exited with status %d."), status)
            let message = self.trimmedOutput(result.output.isEmpty ? statusLine : result.output)
            return CodexLoginAlertInfo(title: L("Grok login failed"), message: message)
        }
    }

    static func managedLoginFailureMessage(for result: CLILoginRunner.Result) -> String {
        let baseMessage = L("managed_grok_login_failed")
        guard let info = self.alertInfo(for: result) else { return baseMessage }
        return "\(baseMessage)\n\n\(L("grok_login_output"))\n\(info.message)"
    }

    @MainActor
    static func presentProgress(_ output: String) {
        let alert = NSAlert()
        alert.messageText = L("Complete Grok login in your browser")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = L("grok_device_login_progress_prefix")
        } else {
            alert.informativeText = "\(L("grok_device_login_progress_prefix"))\n\n\(trimmed)"
        }
        alert.alertStyle = .informational
        alert.runModal()
    }

    private static func trimmedOutput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        if trimmed.isEmpty { return L("No output captured.") }
        if trimmed.count <= limit { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return "\(trimmed[..<idx])…"
    }
}
