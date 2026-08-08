import Foundation

enum KiroLoginAlertPresentation {
    static func alertInfo(for result: KiroLoginRunner.Result) -> CodexLoginAlertInfo? {
        switch result.outcome {
        case .success:
            return nil
        case .missingBinary:
            return CodexLoginAlertInfo(
                title: L("Kiro CLI not found"),
                message: L("Install kiro-cli and try again."))
        case let .launchFailed(message):
            return CodexLoginAlertInfo(title: L("Could not start kiro-cli login"), message: message)
        case .timedOut:
            return CodexLoginAlertInfo(
                title: L("Kiro login timed out"),
                message: self.trimmedOutput(result.output))
        case let .failed(status):
            let statusLine = String(format: L("kiro-cli login exited with status %d."), status)
            let message = self.trimmedOutput(result.output.isEmpty ? statusLine : result.output)
            return CodexLoginAlertInfo(title: L("Kiro login failed"), message: message)
        }
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
