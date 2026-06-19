import Foundation

struct CodexLoginAlertInfo: Equatable {
    let title: String
    let message: String
}

enum CodexLoginAlertPresentation {
    static func alertInfo(for result: CodexLoginRunner.Result) -> CodexLoginAlertInfo? {
        switch result.outcome {
        case .success:
            return nil
        case .missingBinary:
            return CodexLoginAlertInfo(
                title: L("Codex CLI not found"),
                message: L("Install the Codex CLI (npm i -g @openai/codex) and try again."))
        case let .launchFailed(message):
            return CodexLoginAlertInfo(title: L("Could not start codex login"), message: message)
        case .timedOut:
            return CodexLoginAlertInfo(
                title: L("Codex login timed out"),
                message: self.trimmedOutput(result.output))
        case let .failed(status):
            let statusLine = String(format: L("codex login exited with status %d."), status)
            let message = self.trimmedOutput(result.output.isEmpty ? statusLine : result.output)
            return CodexLoginAlertInfo(title: L("Codex login failed"), message: message)
        }
    }

    static func managedLoginFailureMessage(for result: CodexLoginRunner.Result) -> String {
        let baseMessage = L("managed_login_failed")
        guard let info = self.alertInfo(for: result) else { return baseMessage }
        return "\(baseMessage)\n\n\(L("codex_login_output"))\n\(info.message)"
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
