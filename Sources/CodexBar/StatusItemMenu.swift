import AppKit

enum StatusItemMenuProviderNavigationDirection {
    case previous
    case next
}

protocol StatusItemMenuPersistentActionDelegate: AnyObject {
    func performPersistentRefreshAction()
    func performPersistentSettingsAction()
    func performPersistentQuitAction()
    func performProviderNavigation(_ direction: StatusItemMenuProviderNavigationDirection)
    func performProviderSelection(at index: Int)
}

final class StatusItemMenu: NSMenu {
    weak var persistentActionDelegate: StatusItemMenuPersistentActionDelegate?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.persistentAction(for: event) {
            switch action {
            case .refresh:
                self.persistentActionDelegate?.performPersistentRefreshAction()
            case .settings:
                self.persistentActionDelegate?.performPersistentSettingsAction()
            case .quit:
                self.persistentActionDelegate?.performPersistentQuitAction()
            }
            return true
        }
        if let direction = Self.providerNavigationDirection(for: event),
           self.items.first?.view is ProviderSwitcherView
        {
            self.persistentActionDelegate?.performProviderNavigation(direction)
            return true
        }
        if let index = Self.providerSelectionIndex(for: event),
           self.items.first?.view is ProviderSwitcherView
        {
            self.persistentActionDelegate?.performProviderSelection(at: index)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private enum PersistentAction {
        case refresh
        case settings
        case quit
    }

    private nonisolated static func persistentAction(for event: NSEvent) -> PersistentAction? {
        guard event.type == .keyDown else { return nil }

        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevantModifiers == .command else { return nil }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            return .refresh
        case ",":
            return .settings
        case "q":
            return .quit
        default:
            return nil
        }
    }

    nonisolated static func providerNavigationDirection(
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

    nonisolated static func providerSelectionIndex(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevantModifiers == .command,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let number = Int(characters),
              (1...9).contains(number)
        else {
            return nil
        }
        return number - 1
    }
}
