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
                title: "Codex CLI not found",
                message: "Install the Codex CLI (npm i -g @openai/codex) and try again.")
        case let .launchFailed(message):
            return CodexLoginAlertInfo(title: "Could not start codex login", message: message)
        case .timedOut:
            return CodexLoginAlertInfo(
                title: "Codex login timed out",
                message: self.trimmedOutput(result.output))
        case let .failed(status):
            let statusLine = "codex login exited with status \(status)."
            let message = self.trimmedOutput(result.output.isEmpty ? statusLine : result.output)
            return CodexLoginAlertInfo(title: "Codex login failed", message: message)
        }
    }

    private static func trimmedOutput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        if trimmed.isEmpty { return "No output captured." }
        if trimmed.count <= limit { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return "\(trimmed[..<idx])…"
    }
}
