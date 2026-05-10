import AppKit
import CodexBarCore
import Observation
import SwiftUI

extension StatusItemController {
    func switcherWeeklyRemaining(for provider: UsageProvider) -> Double? {
        Self.switcherWeeklyMetricPercent(
            for: provider,
            snapshot: self.store.snapshot(for: provider),
            showUsed: self.settings.usageBarsShowUsed)
    }

    func applySubtitle(_ subtitle: String, to item: NSMenuItem, title: String) {
        if #available(macOS 14.4, *) {
            // NSMenuItem.subtitle is only available on macOS 14.4+.
            item.subtitle = subtitle
        } else {
            item.view = self.makeMenuSubtitleView(title: title, subtitle: subtitle, isEnabled: item.isEnabled)
            item.toolTip = "\(title) — \(subtitle)"
        }
    }

    func makeMenuSubtitleView(title: String, subtitle: String, isEnabled: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.alphaValue = isEnabled ? 1.0 : 0.7

        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        titleField.textColor = NSColor.labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = NSColor.secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }
}

@MainActor
protocol MenuCardHighlighting: AnyObject {
    func setHighlighted(_ highlighted: Bool)
}

@MainActor
protocol MenuCardMeasuring: AnyObject {
    func measuredHeight(width: CGFloat) -> CGFloat
}

@MainActor
@Observable
final class MenuCardHighlightState {
    var isHighlighted = false
}

final class MenuHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool {
        true
    }
}

@MainActor
final class MenuCardItemHostingView<Content: View>: NSHostingView<Content>, MenuCardHighlighting, MenuCardMeasuring {
    private let highlightState: MenuCardHighlightState
    private let onClick: (() -> Void)?

    override var allowsVibrancy: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard self.frame.width > 0 else { return size }
        return NSSize(width: self.frame.width, height: size.height)
    }

    init(rootView: Content, highlightState: MenuCardHighlightState, onClick: (() -> Void)? = nil) {
        self.highlightState = highlightState
        self.onClick = onClick
        super.init(rootView: rootView)
        if onClick != nil {
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handlePrimaryClick(_:)))
            recognizer.buttonMask = 0x1
            self.addGestureRecognizer(recognizer)
        }
    }

    required init(rootView: Content) {
        self.highlightState = MenuCardHighlightState()
        self.onClick = nil
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc private func handlePrimaryClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        self.onClick?()
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let controller = NSHostingController(rootView: self.rootView)
        let measured = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return measured.height
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.highlightState.isHighlighted != highlighted else { return }
        self.highlightState.isHighlighted = highlighted
    }
}

struct MenuCardSectionContainerView<Content: View>: View {
    @Bindable var highlightState: MenuCardHighlightState
    let showsSubmenuIndicator: Bool
    let submenuIndicatorAlignment: Alignment
    let submenuIndicatorTopPadding: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        self.content()
            .environment(\.menuItemHighlighted, self.highlightState.isHighlighted)
            .foregroundStyle(MenuHighlightStyle.primary(self.highlightState.isHighlighted))
            .background(alignment: .topLeading) {
                if self.highlightState.isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(MenuHighlightStyle.selectionBackground(true))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
            .overlay(alignment: self.submenuIndicatorAlignment) {
                if self.showsSubmenuIndicator {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.highlightState.isHighlighted))
                        .padding(.top, self.submenuIndicatorTopPadding)
                        .padding(.trailing, 10)
                }
            }
    }
}

@MainActor
final class PersistentMenuActionItemView: NSView, MenuCardHighlighting {
    private let backgroundView = NSView()
    private let imageView = NSImageView()
    private let titleField: NSTextField
    private let shortcutField: NSTextField?
    private let onClick: () -> Void

    init(
        title: String,
        systemImageName: String?,
        shortcutText: String?,
        width: CGFloat,
        onClick: @escaping () -> Void)
    {
        self.titleField = NSTextField(labelWithString: title)
        self.shortcutField = shortcutText.map(NSTextField.init(labelWithString:))
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: width, height: 28)))
        self.setupView(systemImageName: systemImageName)
        self.setHighlighted(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp else { return }
        self.onClick()
    }

    func setHighlighted(_ highlighted: Bool) {
        let primaryColor = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.controlTextColor
        let secondaryColor = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
        self.backgroundView.isHidden = !highlighted
        self.titleField.textColor = primaryColor
        self.shortcutField?.textColor = secondaryColor
        self.imageView.contentTintColor = primaryColor
    }

    private func setupView(systemImageName: String?) {
        self.backgroundView.wantsLayer = true
        self.backgroundView.layer?.cornerRadius = 6
        self.backgroundView.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        self.backgroundView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.backgroundView)

        if let systemImageName,
           let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
        {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            self.imageView.image = image
        }
        self.imageView.translatesAutoresizingMaskIntoConstraints = false

        self.titleField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.titleField.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(self.imageView)
        stack.addArrangedSubview(self.titleField)
        stack.addArrangedSubview(spacer)
        if let shortcutField {
            shortcutField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
            shortcutField.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(shortcutField)
        }
        self.addSubview(stack)

        NSLayoutConstraint.activate([
            self.backgroundView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            self.backgroundView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            self.backgroundView.topAnchor.constraint(equalTo: self.topAnchor, constant: 2),
            self.backgroundView.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -2),

            self.imageView.widthAnchor.constraint(equalToConstant: 18),
            self.imageView.heightAnchor.constraint(equalToConstant: 18),

            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
    }
}
