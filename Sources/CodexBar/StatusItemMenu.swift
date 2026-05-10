import AppKit

protocol StatusItemMenuPersistentActionDelegate: AnyObject {
    func performPersistentRefreshAction()
}

final class StatusItemMenu: NSMenu {
    weak var persistentActionDelegate: StatusItemMenuPersistentActionDelegate?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isRefreshKeyEquivalent(event) {
            self.persistentActionDelegate?.performPersistentRefreshAction()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private nonisolated static func isRefreshKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }

        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return relevantModifiers == .command
    }
}
