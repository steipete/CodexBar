import AppKit
import CodexBarCore

final class GrokAccountSwitcherView: NSView {
    private let accounts: [GrokVisibleAccount]
    private let onSelect: (GrokVisibleAccount) -> Void
    private var selectedAccountID: String
    private var buttons: [NSButton] = []
    private let preferredSize: NSSize
    private let rowSpacing: CGFloat = 4
    private let rowHeight: CGFloat = 26
    private let selectedBackground = NSColor.controlAccentColor.cgColor
    private let unselectedBackground = NSColor.clear.cgColor
    private let selectedTextColor = NSColor.white
    private let unselectedTextColor = NSColor.secondaryLabelColor
    private let hidePersonalInfo: Bool

    init(
        accounts: [GrokVisibleAccount],
        selectedAccountID: String?,
        width: CGFloat,
        hidePersonalInfo: Bool = false,
        onSelect: @escaping (GrokVisibleAccount) -> Void)
    {
        self.accounts = accounts
        self.onSelect = onSelect
        self.hidePersonalInfo = hidePersonalInfo
        self.selectedAccountID = selectedAccountID ?? accounts.first?.id ?? ""
        let useTwoRows = accounts.count > 3
        let rows = useTwoRows ? 2 : 1
        let height = self.rowHeight * CGFloat(rows) + (useTwoRows ? self.rowSpacing : 0)
        self.preferredSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.wantsLayer = true
        self.buildButtons(useTwoRows: useTwoRows)
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

    private func buildButtons(useTwoRows: Bool) {
        let perRow = useTwoRows ? Int(ceil(Double(self.accounts.count) / 2.0)) : self.accounts.count
        let rows: [[GrokVisibleAccount]] = {
            if !useTwoRows { return [self.accounts] }
            let first = Array(self.accounts.prefix(perRow))
            let second = Array(self.accounts.dropFirst(perRow))
            return [first, second]
        }()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for rowAccounts in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = self.rowSpacing
            row.translatesAutoresizingMaskIntoConstraints = false

            for account in rowAccounts {
                let title = self.buttonTitle(for: account)
                let button = PaddedToggleButton(
                    title: title,
                    target: self,
                    action: #selector(self.handleSelect))
                button.identifier = NSUserInterfaceItemIdentifier(account.id)
                button.toolTip = title
                button.isBordered = false
                button.setButtonType(.toggle)
                button.controlSize = .small
                button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                button.cell?.lineBreakMode = title.contains("@") ? .byTruncatingMiddle : .byTruncatingTail
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
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: self.rowHeight * CGFloat(rows.count) +
                (useTwoRows ? self.rowSpacing : 0)),
        ])
    }

    private func buttonTitle(for account: GrokVisibleAccount) -> String {
        if self.hidePersonalInfo {
            let ordinal = (self.accounts.firstIndex(where: { $0.id == account.id }) ?? 0) + 1
            return L("Account %@", String(ordinal))
        }
        return account.displayName
    }

    private func updateButtonStyles() {
        for (index, button) in self.buttons.enumerated() {
            guard self.accounts.indices.contains(index) else { continue }
            let selected = self.accounts[index].id == self.selectedAccountID
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? self.selectedBackground : self.unselectedBackground
            button.contentTintColor = selected ? self.selectedTextColor : self.unselectedTextColor
        }
    }

    @objc private func handleSelect(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let account = self.accounts.first(where: { $0.id == identifier })
        else { return }
        self.selectedAccountID = account.id
        self.updateButtonStyles()
        self.onSelect(account)
    }

    #if DEBUG
    func _test_buttonToolTips() -> [String] {
        self.buttons.compactMap(\.toolTip)
    }
    #endif
}
