import AppKit

enum StatusItemMenuProviderNavigationDirection {
    case previous
    case next
}

protocol StatusItemMenuPersistentActionDelegate: AnyObject {
    func performPersistentRefreshAction()
    func performProviderNavigation(_ direction: StatusItemMenuProviderNavigationDirection)
}

final class StatusItemMenu: NSMenu {
    weak var persistentActionDelegate: StatusItemMenuPersistentActionDelegate?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isRefreshKeyEquivalent(event) {
            self.persistentActionDelegate?.performPersistentRefreshAction()
            return true
        }
        if let direction = Self.providerNavigationDirection(for: event),
           self.items.first?.view is ProviderSwitcherView
        {
            self.persistentActionDelegate?.performProviderNavigation(direction)
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

    private nonisolated static func providerNavigationDirection(
        for event: NSEvent) -> StatusItemMenuProviderNavigationDirection?
    {
        guard event.type == .keyDown else { return nil }
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevantModifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 123:
            return .previous
        case 124:
            return .next
        default:
            return nil
        }
    }
}
