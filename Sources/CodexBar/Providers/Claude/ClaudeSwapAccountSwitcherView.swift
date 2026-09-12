import AppKit
import CodexBarCore

final class ClaudeSwapAccountSwitcherView: NSView {
    private let accounts: [ProviderAccountUsageSnapshot]
    private let onSelect: (ProviderAccountIdentity) -> Void
    private var buttons: [NSButton] = []
    private var pressedAccountID: ProviderAccountIdentity?
    private var selectionPending: Bool
    private let preferredSize: NSSize

    init(
        display: ClaudeSwapAccountMenuDisplay,
        hidePersonalInfo: Bool,
        width: CGFloat,
        onSelect: @escaping (ProviderAccountIdentity) -> Void)
    {
        self.accounts = display.accounts
        self.onSelect = onSelect
        self.selectionPending = display.switchingAccountID != nil
        let rows = display.accounts.count > 3 ? 2 : 1
        self.preferredSize = NSSize(width: width, height: CGFloat(rows * 26 + (rows - 1) * 4))
        super.init(frame: NSRect(origin: .zero, size: self.preferredSize))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let columns = max(1, (self.accounts.count + rows - 1) / rows)
        for start in stride(from: 0, to: self.accounts.count, by: columns) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 4
            for index in start..<min(start + columns, self.accounts.count) {
                let account = self.accounts[index]
                let label = ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: hidePersonalInfo)
                let button = PaddedToggleButton(title: label, target: self, action: #selector(self.handleSelect))
                button.tag = index
                button.toolTip = label
                button.isBordered = false
                button.setButtonType(.toggle)
                button.controlSize = .small
                button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                button.cell?.lineBreakMode = label.contains("@") ? .byTruncatingMiddle : .byTruncatingTail
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.wantsLayer = true
                button.layer?.cornerRadius = 6
                button.state = account.isActive ? .on : .off
                button.layer?.backgroundColor = account.isActive ? NSColor.controlAccentColor.cgColor : nil
                button.contentTintColor = account.isActive ? .white : .secondaryLabelColor
                button.isEnabled = !self.selectionPending
                row.addArrangedSubview(button)
                self.buttons.append(button)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
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
        self.pressedAccountID = self.accountID(at: self.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { self.pressedAccountID = nil }
        guard let id = self.pressedAccountID,
              self.accountID(at: self.convert(event.locationInWindow, from: nil)) == id
        else { return }
        self.select(id)
    }

    private func accountID(at point: NSPoint) -> ProviderAccountIdentity? {
        guard let button = self.buttons.first(where: { self.convert($0.bounds, from: $0).contains(point) })
        else { return nil }
        return self.accounts[button.tag].id
    }

    @objc private func handleSelect(_ sender: NSButton) {
        guard self.accounts.indices.contains(sender.tag) else { return }
        self.select(self.accounts[sender.tag].id)
    }

    private func select(_ id: ProviderAccountIdentity) {
        guard !self.selectionPending, let account = self.accounts.first(where: { $0.id == id }) else { return }
        if account.canActivate {
            self.selectionPending = true
            for button in self.buttons {
                button.isEnabled = false
            }
        }
        self.onSelect(id)
    }

    #if DEBUG
    func _test_select(_ id: ProviderAccountIdentity) {
        self.select(id)
    }
    #endif
}
