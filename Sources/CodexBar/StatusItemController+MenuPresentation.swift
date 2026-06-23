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
    /// The height AppKit should give this item's menu row. NSMenu reads `intrinsicContentSize`
    /// (not the explicit `frame`) when it lays out custom-view rows, so a measured height that
    /// only lives in `frame` is silently reverted to the open-time row height — leaving the
    /// SwiftUI content centered in a stale, oversized row. Routing the height through the
    /// intrinsic size is the channel the menu actually honors.
    private var measuredHeight: CGFloat?

    override var allowsVibrancy: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        guard let measuredHeight else { return super.intrinsicContentSize }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    func applyMeasuredHeight(width: CGFloat, height: CGFloat) {
        let resolvedHeight = max(1, ceil(height))
        guard self.measuredHeight != resolvedHeight || self.frame.height != resolvedHeight else { return }

        self.measuredHeight = resolvedHeight
        self.frame = NSRect(
            origin: self.frame.origin,
            size: NSSize(width: width, height: resolvedHeight))
        self.invalidateIntrinsicContentSize()
        self.layoutSubtreeIfNeeded()
        self.superview?.layoutSubtreeIfNeeded()
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

    /// `NSMenu` tracking consumes keyboard events before they reach a menu item's custom view, so
    /// the pointer `onClick` path has no native counterpart for assistive tech. Expose the row as an
    /// accessibility button whose press mirrors a click, giving VoiceOver an activation path that runs
    /// `onClick` (and therefore keeps the menu open) instead of regressing to mouse-only.
    override func accessibilityRole() -> NSAccessibility.Role? {
        self.onClick == nil ? super.accessibilityRole() : .button
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick = self.onClick else {
            return super.accessibilityPerformPress()
        }
        onClick()
        return true
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
