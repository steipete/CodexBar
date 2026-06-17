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
    var allowsMenuHighlight: Bool { get }
    func setHighlighted(_ highlighted: Bool)
}

extension MenuCardHighlighting {
    var allowsMenuHighlight: Bool {
        true
    }
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
    let highlightState: MenuCardHighlightState
    private(set) var allowsMenuHighlight: Bool
    private var onClick: (() -> Void)?
    private var hasClickRecognizer = false

    override var allowsVibrancy: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard self.frame.width > 0 else { return size }
        return NSSize(width: self.frame.width, height: size.height)
    }

    init(
        rootView: Content,
        highlightState: MenuCardHighlightState,
        allowsMenuHighlight: Bool,
        onClick: (() -> Void)? = nil)
    {
        self.highlightState = highlightState
        self.allowsMenuHighlight = allowsMenuHighlight
        self.onClick = onClick
        super.init(rootView: rootView)
        if onClick != nil {
            self.installClickRecognizer()
        }
    }

    /// Reuses this hosting view for a rebuilt card with the same identity: the replaced
    /// `rootView` is diffed in place by SwiftUI instead of tearing down and recreating the
    /// hosting view and its graph. Callers must construct `rootView` around this view's own
    /// `highlightState` so menu hover highlighting keeps driving the rendered content.
    func prepareForReuse(rootView: Content, allowsMenuHighlight: Bool, onClick: (() -> Void)?) {
        self.rootView = rootView
        self.allowsMenuHighlight = allowsMenuHighlight
        self.onClick = onClick
        if onClick != nil, !self.hasClickRecognizer {
            self.installClickRecognizer()
        }
    }

    private func installClickRecognizer() {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handlePrimaryClick(_:)))
        recognizer.buttonMask = 0x1
        self.addGestureRecognizer(recognizer)
        self.hasClickRecognizer = true
    }

    required init(rootView: Content) {
        self.highlightState = MenuCardHighlightState()
        self.allowsMenuHighlight = false
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
        self.frame = NSRect(origin: self.frame.origin, size: NSSize(width: width, height: 1))
        self.layoutSubtreeIfNeeded()
        return self.fittingSize.height
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
    var refreshMonitor: MenuCardRefreshMonitor?
    @ViewBuilder let content: () -> Content

    var body: some View {
        self.content()
            .environment(\.menuItemHighlighted, self.highlightState.isHighlighted)
            .environment(\.menuCardRefreshMonitor, self.refreshMonitor)
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
    static let rowHeight: CGFloat = 28

    private let backgroundView = NSView()
    private let imageView = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private let titleField: NSTextField
    private let shortcutField: NSTextField
    private let onClick: () -> Void
    private var isInProgress = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width > 0 ? self.frame.width : NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    override var fittingSize: NSSize {
        NSSize(width: self.frame.width, height: Self.rowHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: Self.rowHeight))
    }

    init(
        title: String,
        systemImageName: String?,
        shortcutText: String?,
        width: CGFloat,
        onClick: @escaping () -> Void)
    {
        self.titleField = NSTextField(labelWithString: title)
        self.shortcutField = NSTextField(labelWithString: shortcutText ?? "")
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: width, height: Self.rowHeight)))
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
        self.shortcutField.textColor = secondaryColor
        self.imageView.contentTintColor = primaryColor
        self.progressIndicator.appearance = highlighted ? NSAppearance(named: .darkAqua) : nil
    }

    /// Gives the persistent Refresh row immediate, in-place feedback while a manual refresh
    /// is in flight: the leading `arrow.clockwise` icon is swapped for a spinner occupying the
    /// same fixed 18×18 slot, so the row height and layout never change (no menu rebuild).
    func setInProgress(_ inProgress: Bool) {
        guard self.isInProgress != inProgress else { return }
        self.isInProgress = inProgress
        // Fade the icon rather than `isHidden`: a hidden NSStackView arranged subview collapses
        // its slot and shifts the title, whereas `alphaValue` keeps the fixed 18pt slot in place.
        self.imageView.alphaValue = inProgress ? 0 : 1
        self.progressIndicator.isHidden = !inProgress
        if inProgress {
            self.progressIndicator.startAnimation(nil)
        } else {
            self.progressIndicator.stopAnimation(nil)
        }
    }

    #if DEBUG
    var isInProgressForTesting: Bool {
        self.isInProgress
    }
    #endif

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

        self.progressIndicator.style = .spinning
        self.progressIndicator.controlSize = .small
        self.progressIndicator.isIndeterminate = true
        self.progressIndicator.isDisplayedWhenStopped = false
        self.progressIndicator.isHidden = true
        self.progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        self.titleField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.titleField.translatesAutoresizingMaskIntoConstraints = false

        self.shortcutField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        self.shortcutField.alignment = .right
        self.shortcutField.lineBreakMode = .byTruncatingTail
        self.shortcutField.setContentHuggingPriority(.required, for: .horizontal)
        self.shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.shortcutField.translatesAutoresizingMaskIntoConstraints = false

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
        stack.addArrangedSubview(self.shortcutField)
        self.addSubview(stack)
        // The spinner overlaps the icon's fixed slot so toggling it never changes row metrics.
        self.addSubview(self.progressIndicator)

        NSLayoutConstraint.activate([
            self.backgroundView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            self.backgroundView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            self.backgroundView.topAnchor.constraint(equalTo: self.topAnchor, constant: 2),
            self.backgroundView.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -2),

            self.imageView.widthAnchor.constraint(equalToConstant: 18),
            self.imageView.heightAnchor.constraint(equalToConstant: 18),
            self.shortcutField.widthAnchor.constraint(equalToConstant: 38),

            self.progressIndicator.centerXAnchor.constraint(equalTo: self.imageView.centerXAnchor),
            self.progressIndicator.centerYAnchor.constraint(equalTo: self.imageView.centerYAnchor),
            self.progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            self.progressIndicator.heightAnchor.constraint(equalToConstant: 16),

            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
    }
}
