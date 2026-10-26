import SwiftUI

/// Draggable chip used by the layout editor for both placed tokens and palette entries.
///
/// Deliberately not a `Button`: on macOS the button's own gesture recognizer claims the mouse-down
/// and the attached `.draggable` never starts a drag session, so neither reordering nor the trash
/// drop zone worked by mouse — the only way to remove a token was the Delete key. Moving
/// `.draggable` onto the button's label does not help, because the button still owns the gesture. A
/// plain view with an explicit tap gesture keeps clicking, dragging, and keyboard activation all
/// working.
struct MenuBarLayoutEditorChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let isDisabled: Bool
    let accessibilityLabel: String
    let accessibilityHint: String?
    let dragItem: MenuBarLayoutDragItem
    let activate: () -> Void
    var removeActionTitle: String?
    var remove: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        dragItem: MenuBarLayoutDragItem,
        activate: @escaping () -> Void,
        removeActionTitle: String? = nil,
        remove: (() -> Void)? = nil)
    {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.dragItem = dragItem
        self.activate = activate
        self.removeActionTitle = removeActionTitle
        self.remove = remove
    }

    var body: some View {
        MenuBarLayoutChipLabel(
            title: self.title,
            systemImage: self.systemImage,
            isSelected: self.isSelected)
            .opacity(self.isDisabled ? 0.4 : 1)
            .contentShape(Capsule(style: .continuous))
            .draggable(self.dragItem)
            .onTapGesture(perform: self.handleActivate)
            .focusable(!self.isDisabled)
            .onKeyPress(keys: [.space, .return], phases: [.down]) { _ in
                guard !self.isDisabled else { return .ignored }
                self.handleActivate()
                return .handled
            }
            .allowsHitTesting(!self.isDisabled)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(self.accessibilityLabel)
            .accessibilityHint(self.accessibilityHint ?? "")
            .accessibilityAction { self.handleActivate() }
            .modifier(OptionalRemoveAccessibilityAction(
                title: self.removeActionTitle,
                remove: self.remove))
    }

    private func handleActivate() {
        guard !self.isDisabled else { return }
        self.activate()
    }
}

/// Adds the named "Remove" accessibility action only for chips that support removal.
private struct OptionalRemoveAccessibilityAction: ViewModifier {
    let title: String?
    let remove: (() -> Void)?

    func body(content: Content) -> some View {
        if let title, let remove {
            content.accessibilityAction(named: title, remove)
        } else {
            content
        }
    }
}
