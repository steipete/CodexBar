import AppKit
import CodexBarCore

enum CodexLocalProfileActionOutcome: Equatable {
    case saved(CodexLocalProfileSaveResult)
    case switched(CodexLocalProfileSwitchResult)

    var didSwitchActiveProfile: Bool {
        switch self {
        case .saved:
            false
        case .switched:
            true
        }
    }

    var successMessage: String {
        switch self {
        case let .saved(result):
            "Saved local Codex profile '\(result.profile.alias)'."
        case let .switched(result):
            "Switched live Codex account to '\(result.profile.alias)'."
        }
    }

    var warningMessage: String? {
        switch self {
        case .saved:
            nil
        case let .switched(result):
            result.reopenError?.localizedDescription
        }
    }
}

@MainActor
struct CodexLocalProfileActionCoordinator {
    enum Action {
        case saveCurrent(named: String)
        case switchToProfile(path: String)

        var confirmationVerb: String {
            switch self {
            case .saveCurrent:
                "save the current account"
            case .switchToProfile:
                "switch the active Codex account"
            }
        }

        var reopensApp: Bool {
            switch self {
            case .saveCurrent:
                false
            case .switchToProfile:
                true
            }
        }
    }

    let manager: CodexLocalProfileManager

    func promptForSaveName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Current Codex Account"
        alert.informativeText = "Enter a name for the current live Codex account."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "plus-a"
        alert.accessoryView = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func perform(_ action: Action) async throws -> CodexLocalProfileActionOutcome? {
        let processes = try await self.manager.runningProcesses()
        if processes.hasRunningProcesses, !self.confirm(processes: processes, action: action) {
            return nil
        }

        switch action {
        case let .saveCurrent(named: name):
            let result = try await self.manager.saveCurrentProfile(
                named: name,
                allowClosingRunningProcesses: processes.hasRunningProcesses)
            return .saved(result)
        case let .switchToProfile(path: path):
            let result = try await self.manager.switchToProfile(
                at: path,
                allowClosingRunningProcesses: processes.hasRunningProcesses)
            return .switched(result)
        }
    }

    private func confirm(processes: CodexLocalProfileRunningProcesses, action: Action) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close Codex before continuing?"
        var details: [String] = []
        if processes.codexAppRunning {
            details.append("Codex.app")
        }
        if !processes.cliProcesses.isEmpty {
            details.append("\(processes.cliProcesses.count) codex CLI session" +
                (processes.cliProcesses.count == 1 ? "" : "s"))
        }
        let restartText = action.reopensApp ? ", then reopen Codex.app." : "."
        alert.informativeText =
            "CodexBar will close \(details.joined(separator: " and ")) to \(action.confirmationVerb)\(restartText)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
