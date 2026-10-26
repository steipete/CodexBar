import AppKit
import CodexBarCore

final class CodexAccountSwitcherView: NSView {
    private let accounts: [CodexVisibleAccount]
    private let hidePersonalInfo: Bool
    private let switcherLabels: [String: String]
    private let accountOrdinals: [String: Int]
    private let onSelect: (CodexVisibleAccount) -> Void
    private var selectedAccountID: String
    private var pressedAccountID: String?
    private var buttons: [NSButton] = []
    private let preferredSize: NSSize
    private let rowSpacing: CGFloat = 4
    private let rowHeight: CGFloat = 26
    private let selectedBackground = NSColor.controlAccentColor.cgColor
    private let unselectedBackground = NSColor.clear.cgColor
    private let selectedTextColor = NSColor.white
    private let unselectedTextColor = NSColor.secondaryLabelColor
    private let buttonFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private let buttonHorizontalPadding: CGFloat = 14
    private let buttonSideInset: CGFloat = 6

    init(
        accounts: [CodexVisibleAccount],
        selectedAccountID: String?,
        width: CGFloat,
        hidePersonalInfo: Bool = false,
        onSelect: @escaping (CodexVisibleAccount) -> Void)
    {
        self.accounts = accounts
        self.hidePersonalInfo = hidePersonalInfo
        self.accountOrdinals = CodexAccountSwitcherLabeling.ordinals(for: accounts)
        self.switcherLabels = CodexAccountSwitcherLabeling.labels(
            for: accounts, hidePersonalInfo: hidePersonalInfo)
        self.onSelect = onSelect
        self.selectedAccountID = selectedAccountID ?? accounts.first?.id ?? ""
        var columns = max(1, accounts.count > 3 ? Int(ceil(Double(accounts.count) / 2)) : accounts.count)
        let font = self.buttonFont
        let discriminatorWidth = accounts.compactMap(\.displayDiscriminator).map {
            ceil(($0 as NSString).size(withAttributes: [.font: font]).width)
        }.max()
        if let discriminatorWidth {
            let contentWidth = max(0, width - self.buttonSideInset * 2)
            let minimumButtonWidth = discriminatorWidth + self.buttonHorizontalPadding
            let fittingColumns = Int((contentWidth + self.rowSpacing) / (minimumButtonWidth + self.rowSpacing))
            columns = min(columns, max(1, fittingColumns))
        }
        let rows = max(1, Int(ceil(Double(accounts.count) / Double(columns))))
        let height = self.rowHeight * CGFloat(rows) + self.rowSpacing * CGFloat(rows - 1)
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

    private func buildButtons(columns: Int) {
        let rows: [[CodexVisibleAccount]] = self.accounts.isEmpty ? [[]] : stride(
            from: 0, to: self.accounts.count, by: columns).map { start in
            Array(self.accounts[start..<min(start + columns, self.accounts.count)])
        }
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

            let buttonWidth = self.buttonWidth(for: rowAccounts.count)
            for account in rowAccounts {
                let title = self.compactButtonTitle(for: account, buttonWidth: buttonWidth)
                let button = PaddedToggleButton(
                    title: title,
                    target: self,
                    action: #selector(self.handleSelect))
                button.identifier = NSUserInterfaceItemIdentifier(account.id)
                button.toolTip = self.resolvedLabel(for: account)
                button.isBordered = false
                button.setButtonType(.toggle)
                button.controlSize = .small
                button.font = self.buttonFont
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
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: self.buttonSideInset),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -self.buttonSideInset),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: self.preferredSize.height),
        ])
    }

    private func resolvedLabel(for account: CodexVisibleAccount) -> String {
        self.switcherLabels[account.id] ?? CodexAccountSwitcherLabeling
            .accountLabel(ordinal: self.accountOrdinals[account.id])
    }

    private func buttonWidth(for count: Int) -> CGFloat {
        let contentWidth = self.bounds.width - (self.buttonSideInset * 2)
        let spacing = self.rowSpacing * CGFloat(max(0, count - 1))
        guard count > 0 else { return contentWidth }
        return max(44, floor((contentWidth - spacing) / CGFloat(count)))
    }

    private func compactButtonTitle(for account: CodexVisibleAccount, buttonWidth: CGFloat) -> String {
        let availableTextWidth = max(24, buttonWidth - self.buttonHorizontalPadding)
        if self.hidePersonalInfo {
            let label = self.resolvedLabel(for: account)
            if self.textWidth(label) <= availableTextWidth { return label }
            let ordinal = self.accountOrdinals[account.id] ?? 1
            let short = CodexAccountSwitcherLabeling.accountLabel(ordinal: ordinal)
            return self.textWidth(short) <= availableTextWidth ? short : String(ordinal)
        }
        if self.textWidth(account.menuDisplayName) <= availableTextWidth {
            return account.menuDisplayName
        }

        if let discriminator = account.displayDiscriminator {
            let suffix = "|\(discriminator)"
            let emailWidth = max(0, availableTextWidth - self.textWidth(suffix))
            guard emailWidth > self.textWidth("…") else { return discriminator }
            return "\(self.truncateMiddle(account.email, toFit: emailWidth))\(suffix)"
        }

        guard let workspace = account.menuWorkspaceLabel else {
            return self.truncateMiddle(account.email, toFit: availableTextWidth)
        }

        let separator = "|"
        let separatorWidth = self.textWidth(separator)
        let contentWidth = max(24, availableTextWidth - separatorWidth)
        let minimumEmailWidth = min(contentWidth * 0.45, max(18, contentWidth * 0.3))
        let minimumWorkspaceWidth = min(contentWidth * 0.4, max(18, contentWidth * 0.25))
        var emailWidth = max(minimumEmailWidth, contentWidth * 0.58)
        var workspaceWidth = max(minimumWorkspaceWidth, contentWidth - emailWidth)

        func makeTitle() -> String {
            let email = self.truncateMiddle(account.email, toFit: emailWidth)
            let workspace = self.truncateTail(workspace, toFit: workspaceWidth)
            return "\(email)\(separator)\(workspace)"
        }

        var title = makeTitle()
        var attempts = 0
        while self.textWidth(title) > availableTextWidth, attempts < 16 {
            let emailText = self.truncateMiddle(account.email, toFit: emailWidth)
            let workspaceText = self.truncateTail(workspace, toFit: workspaceWidth)
            let emailRenderedWidth = self.textWidth(emailText)
            let workspaceRenderedWidth = self.textWidth(workspaceText)

            if emailRenderedWidth >= workspaceRenderedWidth, emailWidth > minimumEmailWidth {
                emailWidth = max(minimumEmailWidth, emailWidth - 6)
            } else if workspaceWidth > minimumWorkspaceWidth {
                workspaceWidth = max(minimumWorkspaceWidth, workspaceWidth - 6)
            } else {
                break
            }

            title = makeTitle()
            attempts += 1
        }

        return title
    }

    private func truncateTail(_ text: String, toFit width: CGFloat) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if self.textWidth(trimmed) <= width {
            return trimmed
        }

        let ellipsis = "…"
        let ellipsisWidth = self.textWidth(ellipsis)
        guard ellipsisWidth < width else { return ellipsis }

        var candidate = ""
        for character in trimmed {
            let next = candidate + String(character)
            if self.textWidth(next + ellipsis) > width {
                break
            }
            candidate = next
        }

        if candidate.isEmpty {
            return ellipsis
        }
        return candidate + ellipsis
    }

    private func truncateMiddle(_ text: String, toFit width: CGFloat) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if self.textWidth(trimmed) <= width {
            return trimmed
        }

        let ellipsis = "…"
        let ellipsisWidth = self.textWidth(ellipsis)
        guard ellipsisWidth < width else { return ellipsis }

        var prefix = ""
        var suffix = ""
        var prefixIndex = trimmed.startIndex
        var suffixIndex = trimmed.endIndex
        var best = ellipsis
        var takeSuffixNext = true

        while prefixIndex < suffixIndex {
            let nextPrefix: String
            let nextSuffix: String
            if takeSuffixNext {
                let previousIndex = trimmed.index(before: suffixIndex)
                nextPrefix = prefix
                nextSuffix = String(trimmed[previousIndex]) + suffix
                suffixIndex = previousIndex
            } else {
                nextPrefix = prefix + String(trimmed[prefixIndex])
                nextSuffix = suffix
                prefixIndex = trimmed.index(after: prefixIndex)
            }

            let candidate = nextPrefix + ellipsis + nextSuffix
            if self.textWidth(candidate) > width {
                break
            }

            prefix = nextPrefix
            suffix = nextSuffix
            best = candidate
            takeSuffixNext.toggle()
        }

        return best
    }

    private func textWidth(_ text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: self.buttonFont]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func updateButtonStyles() {
        for button in self.buttons {
            let selected = button.identifier?.rawValue == self.selectedAccountID
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? self.selectedBackground : self.unselectedBackground
            button.contentTintColor = selected ? self.selectedTextColor : self.unselectedTextColor
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
        let location = self.convert(event.locationInWindow, from: nil)
        self.pressedAccountID = self.accountID(at: location)
    }

    override func mouseUp(with event: NSEvent) {
        defer { self.pressedAccountID = nil }
        guard let pressedAccountID = self.pressedAccountID else { return }
        let location = self.convert(event.locationInWindow, from: nil)
        guard let releasedAccountID = self.accountID(at: location),
              releasedAccountID == pressedAccountID,
              let account = self.accounts.first(where: { $0.id == pressedAccountID })
        else {
            return
        }
        self.applySelection(account)
    }

    private func accountID(at pointInSelf: NSPoint) -> String? {
        self.buttons.first(where: { self.convert($0.bounds, from: $0).contains(pointInSelf) })?.identifier?.rawValue
    }

    @objc private func handleSelect(_ sender: NSButton) {
        guard let accountID = sender.identifier?.rawValue,
              let account = self.accounts.first(where: { $0.id == accountID }) else { return }
        self.applySelection(account)
    }

    private func applySelection(_ account: CodexVisibleAccount) {
        self.selectedAccountID = account.id
        self.updateButtonStyles()
        self.onSelect(account)
    }

    #if DEBUG
    func _test_buttonTitles() -> [String] {
        self.buttons.map(\.title)
    }

    func _test_buttonToolTips() -> [String?] {
        self.buttons.map(\.toolTip)
    }

    func _test_selectAccount(id: String) {
        guard let account = self.accounts.first(where: { $0.id == id }) else { return }
        self.applySelection(account)
    }

    func _test_simulateRuntimeClick(id: String) -> Bool {
        guard let button = self.buttons.first(where: { $0.identifier?.rawValue == id }) else { return false }
        self.updateConstraintsForSubtreeIfNeeded()
        self.layoutSubtreeIfNeeded()
        let point = self.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        guard let mouseDownEvent = NSEvent.mouseEvent(
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
        return self.selectedAccountID == id
    }

    func _test_hitTestSwallowsChildButton(id: String) -> Bool {
        guard let button = self.buttons.first(where: { $0.identifier?.rawValue == id }) else { return false }
        self.updateConstraintsForSubtreeIfNeeded()
        self.layoutSubtreeIfNeeded()
        let point = self.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        return self.hitTest(point) === self
    }

    func _test_toolTipAfterHitTest(id: String) -> String? {
        guard let button = self.buttons.first(where: { $0.identifier?.rawValue == id }) else { return nil }
        self.updateConstraintsForSubtreeIfNeeded()
        self.layoutSubtreeIfNeeded()
        let point = self.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        _ = self.hitTest(point)
        return self.toolTip
    }
    #endif
}
