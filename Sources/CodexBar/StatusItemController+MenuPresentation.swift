import AppKit
import CodexBarCore
import Observation
import SwiftUI

extension StatusItemController {
    func switcherWeeklyRemaining(for provider: UsageProvider) -> Double? {
        let snapshot = self.store.snapshot(for: provider)
        return Self.switcherWeeklyMetricPercent(
            for: provider,
            snapshot: snapshot,
            showUsed: self.settings.usageBarsShowUsed,
            preference: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot))
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

    /// Measures the true SwiftUI content height at `width`. The cached `measuredHeight` is routed
    /// through `intrinsicContentSize`, so `fittingSize` would otherwise echo the stale cached value;
    /// clearing it for the measurement lets the live content size drive the result. Used to resize
    /// the row exactly when expandable content (e.g. status groups) toggles.
    func measuredFittingHeight(width: CGFloat) -> CGFloat {
        let saved = self.measuredHeight
        self.measuredHeight = nil
        self.frame = NSRect(origin: self.frame.origin, size: NSSize(width: width, height: 1))
        self.invalidateIntrinsicContentSize()
        self.layoutSubtreeIfNeeded()
        let height = self.fittingSize.height
        self.measuredHeight = saved
        return height
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

@MainActor
final class PersistentRefreshMenuView: NSView, MenuCardHighlighting {
    private static let minimumShortcutColumnWidth: CGFloat = 44
    private static let titleShortcutGap: CGFloat = 8
    private static let shortcutReferenceText = "⌘ R"

    private let selectionView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let shortcutField: NSTextField?
    private var isRowHighlighted = false
    private var isRowEnabled = true
    private var rowHeight = PersistentRefreshRowMetrics.defaults.rowHeight
    private var onClick: (() -> Void)?

    override var allowsVibrancy: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: self.rowHeight)
    }

    init(
        title: String,
        systemImageName: String?,
        shortcutText: String?,
        onClick: (() -> Void)? = nil)
    {
        self.titleField = NSTextField(labelWithString: title)
        self.shortcutField = shortcutText.map(NSTextField.init(labelWithString:))
        self.onClick = onClick
        super.init(frame: .zero)
        self.setupSelectionView()
        self.setupIconView(systemImageName: systemImageName)
        self.setupTextFields()
        if onClick != nil {
            self.installClickRecognizer()
        }
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        self.onClick == nil ? super.accessibilityRole() : .button
    }

    override func accessibilityLabel() -> String? {
        self.titleField.stringValue
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick = self.onClick else {
            return super.accessibilityPerformPress()
        }
        onClick()
        return true
    }

    func applySize(width: CGFloat, height: CGFloat) {
        self.rowHeight = max(1, ceil(height))
        self.frame = NSRect(origin: .zero, size: NSSize(width: width, height: self.rowHeight))
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.isRowHighlighted != highlighted else { return }
        self.isRowHighlighted = highlighted
        self.selectionView.isHidden = !highlighted
        self.updateColors()
    }

    func setEnabled(_ enabled: Bool) {
        guard self.isRowEnabled != enabled else { return }
        self.isRowEnabled = enabled
        if !enabled {
            self.isRowHighlighted = false
            self.selectionView.isHidden = true
        }
        self.updateColors()
    }

    override func layout() {
        super.layout()

        let metrics = PersistentRefreshRowMetrics.defaults
        self.selectionView.frame = self.bounds.insetBy(
            dx: metrics.selectionHorizontalInset,
            dy: metrics.selectionVerticalInset)
        self.selectionView.layer?.cornerRadius = metrics.selectionCornerRadius

        var leadingX = metrics.leadingPadding
        if self.iconView.image != nil {
            let iconSide = metrics.iconWidth
            self.iconView.symbolConfiguration = Self.iconConfiguration(for: metrics)
            self.iconView.frame = NSRect(
                x: leadingX,
                y: floor((self.bounds.height - iconSide) / 2),
                width: iconSide,
                height: iconSide)
            leadingX += metrics.iconWidth + metrics.iconTitleSpacing
        }

        var titleMaxX = self.bounds.maxX - metrics.trailingPadding
        if let shortcutField {
            shortcutField.font = Self.shortcutFont(for: metrics)
            let shortcutSize = shortcutField.intrinsicContentSize
            let referenceWidth = Self.shortcutReferenceWidth(for: metrics)
            let shortcutColumnWidth = max(Self.minimumShortcutColumnWidth, referenceWidth, shortcutSize.width)
            let shortcutX = self.bounds.maxX
                - metrics.trailingPadding
                + metrics.shortcutXOffset
                - referenceWidth
            shortcutField.frame = NSRect(
                x: shortcutX,
                y: floor((self.bounds.height - shortcutSize.height) / 2) + metrics.shortcutYOffset,
                width: shortcutColumnWidth,
                height: shortcutSize.height)
            titleMaxX = shortcutX - Self.titleShortcutGap
        }

        let titleSize = self.titleField.intrinsicContentSize
        self.titleField.frame = NSRect(
            x: leadingX,
            y: floor((self.bounds.height - titleSize.height) / 2),
            width: max(0, titleMaxX - leadingX),
            height: titleSize.height)
    }

    private func setupSelectionView() {
        self.selectionView.material = .selection
        self.selectionView.blendingMode = .withinWindow
        self.selectionView.state = .active
        self.selectionView.isEmphasized = true
        self.selectionView.isHidden = true
        self.selectionView.wantsLayer = true
        self.selectionView.layer?.masksToBounds = true
        self.addSubview(self.selectionView)
    }

    private func setupIconView(systemImageName: String?) {
        guard let systemImageName,
              let baseImage = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
        else {
            self.iconView.isHidden = true
            return
        }

        baseImage.isTemplate = true
        self.iconView.image = baseImage
        self.iconView.symbolConfiguration = Self.iconConfiguration(for: PersistentRefreshRowMetrics.defaults)
        self.iconView.imageScaling = .scaleProportionallyDown
        self.iconView.contentTintColor = .labelColor
        self.addSubview(self.iconView)
    }

    private func setupTextFields() {
        // Title truncates, shortcut clips; configuring them separately keeps the shortcut column stable.
        self.titleField.font = NSFont.menuFont(ofSize: 0)
        self.configureTitleField(self.titleField)

        if let shortcutField {
            shortcutField.font = Self.shortcutFont(for: PersistentRefreshRowMetrics.defaults)
            self.configureShortcutField(shortcutField)
        }
    }

    private func configureTitleField(_ field: NSTextField) {
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.allowsDefaultTighteningForTruncation = true
        field.backgroundColor = .clear
        self.addSubview(field)
    }

    private func configureShortcutField(_ field: NSTextField) {
        field.alignment = .left
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.allowsDefaultTighteningForTruncation = false
        field.backgroundColor = .clear
        self.addSubview(field)
    }

    private func installClickRecognizer() {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handlePrimaryClick(_:)))
        recognizer.buttonMask = 0x1
        self.addGestureRecognizer(recognizer)
    }

    private func updateColors() {
        guard self.isRowEnabled else {
            self.titleField.textColor = .disabledControlTextColor
            self.shortcutField?.textColor = .disabledControlTextColor
            self.iconView.contentTintColor = .disabledControlTextColor
            return
        }

        if self.isRowHighlighted {
            self.titleField.textColor = .selectedMenuItemTextColor
            self.shortcutField?.textColor = .selectedMenuItemTextColor
            self.iconView.contentTintColor = .selectedMenuItemTextColor
            return
        }

        self.titleField.textColor = .labelColor
        self.shortcutField?.textColor = .tertiaryLabelColor
        self.iconView.contentTintColor = .labelColor
    }

    private static func iconConfiguration(for metrics: PersistentRefreshRowMetrics) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: metrics.iconSymbolPointSize, weight: metrics.iconSymbolWeight)
    }

    private static func shortcutFont(for metrics: PersistentRefreshRowMetrics) -> NSFont {
        NSFont.menuFont(ofSize: metrics.shortcutFontSize)
    }

    private static func shortcutReferenceWidth(for metrics: PersistentRefreshRowMetrics) -> CGFloat {
        (self.shortcutReferenceText as NSString).size(withAttributes: [
            .font: self.shortcutFont(for: metrics),
        ]).width
    }

    @objc private func handlePrimaryClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        guard self.isRowEnabled else { return }
        self.onClick?()
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
