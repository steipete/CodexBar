import AppKit
import Foundation

final class CodexAccountSortControlView: NSView {
    private let onStep: (Int) -> Void
    private let currentMode: CodexMenuAccountSortMode
    private let titleLabel: NSTextField
    private let modeLabel: NSTextField
    private let previousButton: NSButton
    private let nextButton: NSButton

    init(mode: CodexMenuAccountSortMode, width: CGFloat, onStep: @escaping (Int) -> Void) {
        self.currentMode = mode
        self.onStep = onStep
        self.titleLabel = NSTextField(labelWithString: "Sort")
        self.modeLabel = NSTextField(labelWithString: mode.compactTitle)
        self.previousButton = NSButton(title: "", target: nil, action: nil)
        self.nextButton = NSButton(title: "", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        self.wantsLayer = true
        self.buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: 30)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds.insetBy(dx: 10, dy: 0)
        let centerY = bounds.midY
        let buttonSize = NSSize(width: 20, height: 20)

        self.nextButton.frame = NSRect(
            x: bounds.maxX - buttonSize.width,
            y: centerY - buttonSize.height / 2,
            width: buttonSize.width,
            height: buttonSize.height)

        self.previousButton.frame = NSRect(
            x: self.nextButton.frame.minX - 6 - buttonSize.width,
            y: centerY - buttonSize.height / 2,
            width: buttonSize.width,
            height: buttonSize.height)

        self.titleLabel.sizeToFit()
        self.titleLabel.frame = NSRect(
            x: bounds.minX,
            y: centerY - 9,
            width: min(60, self.titleLabel.frame.width),
            height: 18)

        let modeX = self.titleLabel.frame.maxX + 8
        let modeWidth = max(40, self.previousButton.frame.minX - 8 - modeX)
        self.modeLabel.frame = NSRect(
            x: modeX,
            y: centerY - 9,
            width: modeWidth,
            height: 18)
    }

    private func buildUI() {
        self.titleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        self.titleLabel.textColor = .labelColor
        self.titleLabel.alignment = .left
        self.titleLabel.lineBreakMode = .byClipping

        self.modeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        self.modeLabel.textColor = .secondaryLabelColor
        self.modeLabel.alignment = .right
        self.modeLabel.lineBreakMode = .byTruncatingTail

        self.configureButton(self.previousButton, action: #selector(self.previousMode))
        self.configureButton(self.nextButton, action: #selector(self.nextMode))

        if let previousImage = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "Previous sort mode")
        {
            previousImage.isTemplate = true
            self.previousButton.image = previousImage
        } else {
            self.previousButton.title = "◀"
        }
        if let nextImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next sort mode") {
            nextImage.isTemplate = true
            self.nextButton.image = nextImage
        } else {
            self.nextButton.title = "▶"
        }

        self.addSubview(self.titleLabel)
        self.addSubview(self.modeLabel)
        self.addSubview(self.previousButton)
        self.addSubview(self.nextButton)
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = true
        button.bezelStyle = .texturedRounded
        button.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
    }

    @objc private func previousMode() {
        self.onStep(-1)
    }

    @objc private func nextMode() {
        self.onStep(1)
    }
}
