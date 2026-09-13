import AppKit

/// One account in an `AccountSegmentedSwitcherView`. Providers own labeling; the view owns layout and state.
struct AccountSwitcherSegment {
    let id: String
    /// Unabbreviated label for tooltips and VoiceOver. Must already honor Hide Personal Info.
    let fullLabel: String
    /// True for the account the provider's own CLI currently uses.
    let isSystem: Bool
    /// Fits a title into an available width, measuring text with the supplied closure.
    let title: (_ availableWidth: CGFloat, _ measure: (String) -> CGFloat) -> String
    /// Shortest title that must stay readable; reduces the column count when it cannot fit.
    var minimumTitle: String?
}

/// Segmented account switcher shared by providers. The filled segment is the Selected account; a leading `●`
/// marks the System account (the one the provider CLI uses). The two states are independent.
final class AccountSegmentedSwitcherView: NSView {
    static let systemMarker = "●"

    private static let rowSpacing: CGFloat = 4
    private static let rowHeight: CGFloat = 26
    private static let buttonHorizontalPadding: CGFloat = 14
    private static let buttonSideInset: CGFloat = 6
    private static let buttonFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private let segments: [AccountSwitcherSegment]
    private let onSelect: (String) -> Void
    private var selectedID: String?
    private var pressedID: String?
    private var buttons: [NSButton] = []
    private let preferredSize: NSSize

    init(
        segments: [AccountSwitcherSegment],
        selectedID: String?,
        width: CGFloat,
        onSelect: @escaping (String) -> Void)
    {
        self.segments = segments
        self.onSelect = onSelect
        self.selectedID = selectedID
        var columns = max(1, segments.count > 3 ? Int(ceil(Double(segments.count) / 2)) : segments.count)
        if let minimumWidth = segments.compactMap(\.minimumTitle).map({ Self.measure($0) }).max() {
            let contentWidth = max(0, width - Self.buttonSideInset * 2)
            let minimumButtonWidth = minimumWidth + Self.buttonHorizontalPadding
            let fitting = Int((contentWidth + Self.rowSpacing) / (minimumButtonWidth + Self.rowSpacing))
            columns = min(columns, max(1, fitting))
        }
        let rows = max(1, Int(ceil(Double(segments.count) / Double(columns))))
        let height = Self.rowHeight * CGFloat(rows) + Self.rowSpacing * CGFloat(rows - 1)
        self.preferredSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.wantsLayer = true
        self.buildButtons(columns: columns)
        self.updateButtonStyles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        self.preferredSize
    }

    override var fittingSize: NSSize {
        self.preferredSize
    }

    /// Privacy-safe description: reuses the already redacted label and only appends state words.
    static func accessibilityDescription(fullLabel: String, isSystem: Bool, isSelected: Bool) -> String {
        var description = fullLabel
        if isSystem {
            description += " — " + L("System")
        }
        if isSelected {
            description += " — " + L("Selected")
        }
        return description
    }

    private static func measure(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: self.buttonFont]).width)
    }

    private func buildButtons(columns: Int) {
        let rows: [[AccountSwitcherSegment]] = self.segments.isEmpty ? [[]] : stride(
            from: 0, to: self.segments.count, by: columns).map { start in
            Array(self.segments[start..<min(start + columns, self.segments.count)])
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = Self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for rowSegments in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = Self.rowSpacing
            row.translatesAutoresizingMaskIntoConstraints = false

            let buttonWidth = self.buttonWidth(for: rowSegments.count)
            for segment in rowSegments {
                let button = PaddedToggleButton(
                    title: self.title(for: segment, buttonWidth: buttonWidth),
                    target: self,
                    action: #selector(self.handleSelect))
                button.identifier = NSUserInterfaceItemIdentifier(segment.id)
                button.isBordered = false
                button.setButtonType(.toggle)
                button.controlSize = .small
                button.font = Self.buttonFont
                button.cell?.lineBreakMode = .byTruncatingTail
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.wantsLayer = true
                button.layer?.cornerRadius = 6
                row.addArrangedSubview(button)
                self.buttons.append(button)
            }

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Self.buttonSideInset),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Self.buttonSideInset),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: self.preferredSize.height),
        ])
    }

    private func buttonWidth(for count: Int) -> CGFloat {
        let contentWidth = self.bounds.width - (Self.buttonSideInset * 2)
        let spacing = Self.rowSpacing * CGFloat(max(0, count - 1))
        guard count > 0 else { return contentWidth }
        return max(44, floor((contentWidth - spacing) / CGFloat(count)))
    }

    private func title(for segment: AccountSwitcherSegment, buttonWidth: CGFloat) -> String {
        let available = max(24, buttonWidth - Self.buttonHorizontalPadding)
        guard segment.isSystem else { return segment.title(available, Self.measure) }
        let marker = Self.systemMarker + " "
        return marker + segment.title(max(12, available - Self.measure(marker)), Self.measure)
    }

    private func updateButtonStyles() {
        for (button, segment) in zip(self.buttons, self.segments) {
            let selected = segment.id == self.selectedID
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            button.contentTintColor = selected ? .white : (segment.isSystem ? .labelColor : .secondaryLabelColor)
            let description = Self.accessibilityDescription(
                fullLabel: segment.fullLabel,
                isSystem: segment.isSystem,
                isSelected: selected)
            button.toolTip = description
            button.setAccessibilityLabel(description)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let descendant = super.hitTest(point)
        if descendant != nil, descendant !== self {
            self.toolTip = (descendant as? NSButton)?.toolTip
            return self
        }
        self.toolTip = nil
        return descendant
    }

    override func mouseDown(with event: NSEvent) {
        self.pressedID = self.segmentID(at: self.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { self.pressedID = nil }
        guard let pressedID = self.pressedID,
              self.segmentID(at: self.convert(event.locationInWindow, from: nil)) == pressedID
        else { return }
        self.applySelection(id: pressedID)
    }

    private func segmentID(at point: NSPoint) -> String? {
        self.buttons.first(where: { self.convert($0.bounds, from: $0).contains(point) })?.identifier?.rawValue
    }

    @objc private func handleSelect(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        self.applySelection(id: id)
    }

    private func applySelection(id: String) {
        guard self.segments.contains(where: { $0.id == id }) else { return }
        self.selectedID = id
        self.updateButtonStyles()
        self.onSelect(id)
    }

    #if DEBUG
    func _test_buttonTitles() -> [String] {
        self.buttons.map(\.title)
    }

    func _test_buttonToolTips() -> [String?] {
        self.buttons.map(\.toolTip)
    }

    /// Titles of the segments drawn as selected.
    var _test_selectedTitles: [String] {
        self.buttons.filter { $0.state == .on }.map(\.title)
    }

    func _test_buttons() -> [NSButton] {
        self.buttons
    }

    func _test_selectAccount(id: String) {
        self.applySelection(id: id)
    }

    func _test_simulateRuntimeClick(id: String) -> Bool {
        guard let point = self.centerOfButton(id: id),
              let mouseDownEvent = NSEvent.mouseEvent(
                  with: .leftMouseDown,
                  location: point,
                  modifierFlags: [],
                  timestamp: 0,
                  windowNumber: 0,
                  context: nil,
                  eventNumber: 1,
                  clickCount: 1,
                  pressure: 1),
              let mouseUpEvent = NSEvent.mouseEvent(
                  with: .leftMouseUp,
                  location: point,
                  modifierFlags: [],
                  timestamp: 0,
                  windowNumber: 0,
                  context: nil,
                  eventNumber: 2,
                  clickCount: 1,
                  pressure: 0)
        else {
            return false
        }
        self.mouseDown(with: mouseDownEvent)
        self.mouseUp(with: mouseUpEvent)
        return self.selectedID == id
    }

    func _test_hitTestSwallowsChildButton(id: String) -> Bool {
        guard let point = self.centerOfButton(id: id) else { return false }
        return self.hitTest(point) === self
    }

    func _test_toolTipAfterHitTest(id: String) -> String? {
        guard let point = self.centerOfButton(id: id) else { return nil }
        _ = self.hitTest(point)
        return self.toolTip
    }

    private func centerOfButton(id: String) -> NSPoint? {
        guard let button = self.buttons.first(where: { $0.identifier?.rawValue == id }) else { return nil }
        self.updateConstraintsForSubtreeIfNeeded()
        self.layoutSubtreeIfNeeded()
        return self.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
    }
    #endif
}
