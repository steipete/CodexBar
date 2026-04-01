import AppKit
import Foundation

final class CodexMenuDisplayModeToggleView: NSView {
    private static let controlHeight: CGFloat = 24
    private static let viewHeight: CGFloat = 28
    private static let horizontalPadding: CGFloat = 2
    private static let trackSideInset: CGFloat = 12
    private static let interSegmentSpacing: CGFloat = 2
    private static let buttonFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    private let onSelect: (CodexMenuDisplayMode) -> Void
    private let selectedMode: CodexMenuDisplayMode
    private let selectedBackground = NSColor.controlAccentColor.cgColor
    private let unselectedBackground = NSColor.clear.cgColor
    private let trackBackground = NSColor.white.withAlphaComponent(0.08).cgColor
    private let trackBorderColor = NSColor.white.withAlphaComponent(0.10).cgColor
    private let selectedTextColor = NSColor.white
    private let unselectedTextColor = NSColor.labelColor.withAlphaComponent(0.82)
    private var buttons: [CodexMenuDisplayMode: NSButton] = [:]
    private var orderedButtons: [NSButton] = []

    init(
        selectedMode: CodexMenuDisplayMode,
        width: CGFloat,
        onSelect: @escaping (CodexMenuDisplayMode) -> Void)
    {
        self.selectedMode = selectedMode
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.viewHeight))
        self.buildUI()
        self.updateButtonStyles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: Self.viewHeight)
    }

    private func buildUI() {
        let trackView = NSView()
        trackView.wantsLayer = true
        trackView.layer?.backgroundColor = self.trackBackground
        trackView.layer?.borderColor = self.trackBorderColor
        trackView.layer?.borderWidth = 1
        trackView.layer?.cornerRadius = 9
        trackView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.interSegmentSpacing
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        for mode in [CodexMenuDisplayMode.all, .single] {
            let title = switch mode {
            case .single: "Single"
            case .all: "All"
            }
            let button = PaddedToggleButton(
                title: title,
                target: self,
                action: #selector(self.handleSelect(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            button.contentPadding = NSEdgeInsets(top: 2, left: 11, bottom: 2, right: 11)
            button.isBordered = false
            button.focusRingType = .none
            button.setButtonType(.toggle)
            button.controlSize = .small
            button.font = Self.buttonFont
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            self.buttons[mode] = button
            self.orderedButtons.append(button)
            stack.addArrangedSubview(button)
        }

        trackView.addSubview(stack)
        self.addSubview(trackView)

        NSLayoutConstraint.activate([
            trackView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Self.trackSideInset),
            trackView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Self.trackSideInset),
            trackView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            trackView.heightAnchor.constraint(equalToConstant: Self.controlHeight),

            stack.leadingAnchor.constraint(equalTo: trackView.leadingAnchor, constant: Self.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trackView.trailingAnchor, constant: -Self.horizontalPadding),
            stack.topAnchor.constraint(equalTo: trackView.topAnchor, constant: Self.horizontalPadding),
            stack.bottomAnchor.constraint(equalTo: trackView.bottomAnchor, constant: -Self.horizontalPadding),
        ])
    }

    private func updateButtonStyles() {
        for (mode, button) in self.buttons {
            let selected = mode == self.selectedMode
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? self.selectedBackground : self.unselectedBackground
            self.applyTitleColor(selected ? self.selectedTextColor : self.unselectedTextColor, to: button)
        }
    }

    private func applyTitleColor(_ color: NSColor, to button: NSButton) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: button.font ?? Self.buttonFont,
            .foregroundColor: color,
        ]
        let title = NSAttributedString(string: button.title, attributes: attributes)
        button.attributedTitle = title
        button.attributedAlternateTitle = title
    }

    @objc private func handleSelect(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let mode = CodexMenuDisplayMode(rawValue: rawValue)
        else {
            return
        }
        self.onSelect(mode)
    }

    func _test_buttonTitles() -> [String] {
        self.orderedButtons.map(\.title)
    }
}
