import Foundation

enum CodexStatusMarkers {
    static let status = [
        "Credits:",
        "5h limit",
        "5-hour limit",
        "Weekly limit",
    ].map { Data($0.utf8) }

    static let updatePrompt = [
        "Update available!",
        "Run bun install -g @openai/codex",
        "0.60.1 ->",
    ].map { Data($0.lowercased().utf8) }

    static let longestStatus = CodexStatusMarkers.status.map(\.count).max() ?? 0
    static let longestUpdatePrompt = CodexStatusMarkers.updatePrompt.map(\.count).max() ?? 0
}
