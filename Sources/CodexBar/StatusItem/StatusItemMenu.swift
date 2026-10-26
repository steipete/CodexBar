import AppKit
import CodexBarCore

enum StatusItemMenuProviderNavigationDirection {
    case previous
    case next
}

protocol StatusItemMenuPersistentActionDelegate: AnyObject {
    func performPersistentRefreshAction(
        in menuID: ObjectIdentifier,
        menuInteractionGeneration: Int)
    func performPersistentSettingsAction()
    func performPersistentQuitAction()
    func performProviderNavigation(_ direction: StatusItemMenuProviderNavigationDirection)
}

final class StatusItemMenu: NSMenu {
    weak var persistentActionDelegate: StatusItemMenuPersistentActionDelegate?
    var menuInteractionGeneration: Int?
    var switcherShortcuts: () -> [String: String] = { ProviderSwitcherShortcuts.defaults }

    func requestPersistentRefreshAction() {
        guard let menuInteractionGeneration else { return }
        self.persistentActionDelegate?.performPersistentRefreshAction(
            in: ObjectIdentifier(self),
            menuInteractionGeneration: menuInteractionGeneration)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.persistentAction(for: event) {
            switch action {
            case .refresh:
                self.requestPersistentRefreshAction()
            case .settings:
                self.persistentActionDelegate?.performPersistentSettingsAction()
            case .quit:
                self.persistentActionDelegate?.performPersistentQuitAction()
            }
            return true
        }
        if let direction = Self.providerNavigationDirection(for: event, mapping: self.switcherShortcuts()),
           self.items.first?.view is ProviderSwitcherView
        {
            self.persistentActionDelegate?.performProviderNavigation(direction)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private enum PersistentAction {
        case refresh
        case settings
        case quit
    }

    nonisolated static func isPersistentRefreshShortcut(for event: NSEvent) -> Bool {
        self.persistentAction(for: event) == .refresh
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

    nonisolated static func providerShortcutAction(
        for event: NSEvent, mapping: [String: String] = ProviderSwitcherShortcuts.defaults) -> String?
    {
        guard event.type == .keyDown else { return nil }
        let characters = event.modifierFlags.contains(.shift)
            ? event.characters(byApplyingModifiers: []) : event.charactersIgnoringModifiers
        let key = switch event.keyCode {
        case 123: "left"
        case 124: "right"
        default: characters?.lowercased() ?? ""
        }
        let modifiers: [(NSEvent.ModifierFlags, String)] = [
            (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
        ]
        return ProviderSwitcherShortcuts.action(
            key: key, modifiers: modifiers.filter { event.modifierFlags.contains($0.0) }.map(\.1), mapping: mapping)
    }

    nonisolated static func providerNavigationDirection(
        for event: NSEvent, mapping: [String: String] = ProviderSwitcherShortcuts.defaults)
        -> StatusItemMenuProviderNavigationDirection?
    {
        switch self.providerShortcutAction(for: event, mapping: mapping) {
        case "previous": .previous
        case "next": .next
        default: nil
        }
    }

    nonisolated static func providerSelectionIndex(
        for event: NSEvent, mapping: [String: String] = ProviderSwitcherShortcuts.defaults) -> Int?
    {
        guard let action = self.providerShortcutAction(for: event, mapping: mapping),
              action.hasPrefix("select"), let index = Int(action.dropFirst(6)) else { return nil }
        return index - 1
    }
}
