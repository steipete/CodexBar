import AppKit

extension StatusItemController {
    func makeWrappedSecondaryTextItem(text: String, width: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = self.makeWrappedSecondaryTextView(text: text)
        let height = self.menuTextItemHeight(for: view, width: width)
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        item.view = view
        item.isEnabled = false
        item.toolTip = text
        return item
    }

    private func makeWrappedSecondaryTextView(text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = NSColor.secondaryLabelColor
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textField)
        // macos-smell:disable MACOS005
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            textField.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }

    private func menuTextItemHeight(for view: NSView, width: CGFloat) -> CGFloat {
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        view.layoutSubtreeIfNeeded()
        return max(1, ceil(view.fittingSize.height))
    }
}
