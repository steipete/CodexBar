import AppKit

final class PaddedToggleButton: NSButton {
    var contentPadding = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7) {
        didSet {
            if oldValue.top != self.contentPadding.top ||
                oldValue.left != self.contentPadding.left ||
                oldValue.bottom != self.contentPadding.bottom ||
                oldValue.right != self.contentPadding.right
            {
                self.invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(
            width: size.width + self.contentPadding.left + self.contentPadding.right,
            height: size.height + self.contentPadding.top + self.contentPadding.bottom)
    }
}

final class InlineIconToggleButton: NSButton {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var paddingConstraints: [NSLayoutConstraint] = []
    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var isConfiguring = false // Batch invalidation during setup

    var contentPadding = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7) {
        didSet {
            self.paddingConstraints.first { $0.firstAttribute == .top }?.constant = self.contentPadding.top
            self.paddingConstraints.first { $0.firstAttribute == .leading }?.constant = self.contentPadding.left
            self.paddingConstraints.first { $0.firstAttribute == .trailing }?.constant = -self.contentPadding.right
            self.paddingConstraints.first { $0.firstAttribute == .bottom }?.constant = -(self.contentPadding.bottom + 4)
            if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
        }
    }

    override var title: String {
        get { "" }
        set {
            super.title = ""
            super.alternateTitle = ""
            super.attributedTitle = NSAttributedString(string: "")
            super.attributedAlternateTitle = NSAttributedString(string: "")
            self.titleField.stringValue = newValue
            if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
        }
    }

    override var image: NSImage? {
        get { nil }
        set {
            super.image = nil
            super.alternateImage = nil
            self.iconView.image = newValue
            if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
        }
    }

    func setContentTintColor(_ color: NSColor?) {
        self.iconView.contentTintColor = color
        self.titleField.textColor = color
    }

    func setIconSize(_ size: CGFloat) {
        guard self.iconSizeConstraints.count == 2 else { return }
        self.iconSizeConstraints[0].constant = size
        self.iconSizeConstraints[1].constant = size
        if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
    }

    func setTitleFontSize(_ size: CGFloat) {
        self.titleField.font = NSFont.systemFont(ofSize: size)
    }

    func setAllowsTwoLineTitle(_ allow: Bool) {
        let hasWhitespace = self.titleField.stringValue.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let shouldWrap = allow && hasWhitespace
        self.titleField.maximumNumberOfLines = shouldWrap ? 2 : 1
        self.titleField.usesSingleLineMode = !shouldWrap
        self.titleField.lineBreakMode = shouldWrap ? .byWordWrapping : .byTruncatingTail
    }

    override var intrinsicContentSize: NSSize {
        let size = self.stack.fittingSize
        return NSSize(
            width: size.width + self.contentPadding.left + self.contentPadding.right,
            height: size.height + self.contentPadding.top + self.contentPadding.bottom)
    }

    init(title: String, image: NSImage, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.isConfiguring = true // Batch invalidations during setup
        self.configure()
        self.title = title
        self.image = image
        self.isConfiguring = false
        self.invalidateIntrinsicContentSize() // Single invalidation after setup
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.setButtonType(.toggle)
        self.controlSize = .small
        self.wantsLayer = true

        self.iconView.imageScaling = .scaleProportionallyUpOrDown
        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.titleField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        self.titleField.alignment = .left
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.setContentTintColor(NSColor.secondaryLabelColor)

        self.stack.orientation = .horizontal
        self.stack.alignment = .centerY
        self.stack.spacing = 1
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack.addArrangedSubview(self.iconView)
        self.stack.addArrangedSubview(self.titleField)
        self.addSubview(self.stack)

        let iconWidth = self.iconView.widthAnchor.constraint(equalToConstant: 16)
        let iconHeight = self.iconView.heightAnchor.constraint(equalToConstant: 16)
        self.iconSizeConstraints = [iconWidth, iconHeight]

        let top = self.stack.topAnchor.constraint(
            equalTo: self.topAnchor,
            constant: self.contentPadding.top)
        let leading = self.stack.leadingAnchor.constraint(
            greaterThanOrEqualTo: self.leadingAnchor,
            constant: self.contentPadding.left)
        let trailing = self.stack.trailingAnchor.constraint(
            lessThanOrEqualTo: self.trailingAnchor,
            constant: -self.contentPadding.right)
        let centerX = self.stack.centerXAnchor.constraint(equalTo: self.centerXAnchor)
        centerX.priority = .defaultHigh
        let bottom = self.stack.bottomAnchor.constraint(
            lessThanOrEqualTo: self.bottomAnchor,
            constant: -(self.contentPadding.bottom + 4))
        self.paddingConstraints = [top, leading, trailing, bottom, centerX]

        NSLayoutConstraint.activate(self.paddingConstraints + self.iconSizeConstraints)
    }
}

final class StackedToggleButton: NSButton {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var paddingConstraints: [NSLayoutConstraint] = []
    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var isConfiguring = false // Batch invalidation during setup

    var contentPadding = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4) {
        didSet {
            self.paddingConstraints.first { $0.firstAttribute == .top }?.constant = self.contentPadding.top
            self.paddingConstraints.first { $0.firstAttribute == .leading }?.constant = self.contentPadding.left
            self.paddingConstraints.first { $0.firstAttribute == .trailing }?.constant = -self.contentPadding.right
            self.paddingConstraints.first { $0.firstAttribute == .bottom }?.constant = -self.contentPadding.bottom
            if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
        }
    }

    override var title: String {
        get { "" }
        set {
            super.title = ""
            super.alternateTitle = ""
            super.attributedTitle = NSAttributedString(string: "")
            super.attributedAlternateTitle = NSAttributedString(string: "")
            self.titleField.stringValue = newValue
            if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
        }
    }

    override var image: NSImage? {
        get { nil }
        set {
            super.image = nil
            super.alternateImage = nil
            self.iconView.image = newValue
            if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
        }
    }

    func setContentTintColor(_ color: NSColor?) {
        self.iconView.contentTintColor = color
        self.titleField.textColor = color
    }

    func setIconSize(_ size: CGFloat) {
        guard self.iconSizeConstraints.count == 2 else { return }
        self.iconSizeConstraints[0].constant = size
        self.iconSizeConstraints[1].constant = size
        if !self.isConfiguring { self.invalidateIntrinsicContentSize() }
    }

    func setTitleFontSize(_ size: CGFloat) {
        self.titleField.font = NSFont.systemFont(ofSize: size)
    }

    func setAllowsTwoLineTitle(_ allow: Bool) {
        let hasWhitespace = self.titleField.stringValue.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let shouldWrap = allow && hasWhitespace
        self.titleField.maximumNumberOfLines = shouldWrap ? 2 : 1
        self.titleField.usesSingleLineMode = !shouldWrap
        self.titleField.lineBreakMode = shouldWrap ? .byWordWrapping : .byTruncatingTail
    }

    override var intrinsicContentSize: NSSize {
        let size = self.stack.fittingSize
        return NSSize(
            width: size.width + self.contentPadding.left + self.contentPadding.right,
            height: size.height + self.contentPadding.top + self.contentPadding.bottom)
    }

    init(title: String, image: NSImage, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.isConfiguring = true // Batch invalidations during setup
        self.configure()
        self.title = title
        self.image = image
        self.isConfiguring = false
        self.invalidateIntrinsicContentSize() // Single invalidation after setup
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.setButtonType(.toggle)
        self.controlSize = .small
        self.wantsLayer = true

        self.iconView.imageScaling = .scaleProportionallyUpOrDown
        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.titleField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 2)
        self.titleField.alignment = .center
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.maximumNumberOfLines = 1
        self.titleField.usesSingleLineMode = true
        self.setContentTintColor(NSColor.secondaryLabelColor)

        self.stack.orientation = .vertical
        self.stack.alignment = .centerX
        self.stack.spacing = 0
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack.addArrangedSubview(self.iconView)
        self.stack.addArrangedSubview(self.titleField)
        self.addSubview(self.stack)

        let iconWidth = self.iconView.widthAnchor.constraint(equalToConstant: 16)
        let iconHeight = self.iconView.heightAnchor.constraint(equalToConstant: 16)
        self.iconSizeConstraints = [iconWidth, iconHeight]

        // Avoid subpixel centering: pin from the top so the icon sits on whole-point coordinates.
        // Force an even layout width (button width minus padding) so the icon doesn't land on 0.5pt centers.
        // Reserve some bottom space for the "weekly remaining" indicator line.
        let top = self.stack.topAnchor.constraint(
            equalTo: self.topAnchor,
            constant: self.contentPadding.top)
        let leading = self.stack.leadingAnchor.constraint(
            equalTo: self.leadingAnchor,
            constant: self.contentPadding.left)
        let trailing = self.stack.trailingAnchor.constraint(
            equalTo: self.trailingAnchor,
            constant: -self.contentPadding.right)
        let bottom = self.stack.bottomAnchor.constraint(
            lessThanOrEqualTo: self.bottomAnchor,
            constant: -(self.contentPadding.bottom + 4))
        self.paddingConstraints = [top, leading, trailing, bottom]

        NSLayoutConstraint.activate(self.paddingConstraints + self.iconSizeConstraints)
    }
}
