import AppKit
import QuartzCore
import SwiftUI

/// Keep the native menu row on screen; only the chart document scrolls when history is tall.
@MainActor
final class CostHistoryMenuScrollView: NSScrollView {
    private let resizeDocument: (CGFloat, CGFloat) -> Void
    private let measureDocument: (CGFloat) -> CGFloat
    private var maximumHeight: CGFloat = 620
    private var measuredWidth: CGFloat?
    private var documentHeight: CGFloat = 1
    private var maximumDocumentHeight: CGFloat = 1
    private let maximumHeightGrowth: CGFloat
    private var availableHeightBelowAnchor: CGFloat?
    private var viewportSize = NSSize(width: 1, height: 1)

    init(
        hosting: MenuHostingView<some View>,
        width: CGFloat,
        maximumHeight: CGFloat,
        maximumHeightGrowth: CGFloat = 0,
        availableHeightBelowAnchor: CGFloat? = nil)
    {
        self.maximumHeightGrowth = max(0, maximumHeightGrowth)
        self.availableHeightBelowAnchor = availableHeightBelowAnchor
        self.resizeDocument = { width, height in
            hosting.applyMeasuredHeight(width: width, height: height)
        }
        self.measureDocument = { width in
            let height = hosting.measuredFittingHeight(width: width)
            hosting.applyMeasuredHeight(width: width, height: height)
            return height
        }
        super.init(frame: .zero)
        self.borderType = .noBorder
        self.drawsBackground = false
        self.hasVerticalScroller = true
        self.hasHorizontalScroller = false
        self.autohidesScrollers = true
        self.scrollerStyle = .overlay
        self.documentView = hosting
        self.updateSize(width: width, maximumHeight: maximumHeight)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        self.viewportSize
    }

    override var fittingSize: NSSize {
        self.viewportSize
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let screen = self.window?.screen else { return }
        self.updateSize(width: self.viewportSize.width, maximumHeight: Self.maximumHeight(on: screen))
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        self.updateSize(width: width, maximumHeight: self.maximumHeight)
        return self.viewportSize.height
    }

    func updateSize(width: CGFloat, maximumHeight: CGFloat, availableHeightBelowAnchor: CGFloat? = nil) {
        self.maximumHeight = maximumHeight
        if let availableHeightBelowAnchor {
            self.availableHeightBelowAnchor = availableHeightBelowAnchor
        }
        if self.measuredWidth != width {
            let height = max(1, ceil(self.measureDocument(width)))
            self.maximumDocumentHeight = self.measuredWidth == nil
                ? height + self.maximumHeightGrowth
                : max(height, self.maximumDocumentHeight + height - self.documentHeight)
            self.documentHeight = height
            self.measuredWidth = width
        }
        let limit = max(1, maximumHeight)
        let largestViewportHeight = min(self.maximumDocumentHeight, limit)
        // Reserve the largest layout before AppKit positions a menu that cannot grow downward.
        // The document keeps its natural height and stays pinned to the top of the viewport.
        let reservesHeight = self.availableHeightBelowAnchor.map { largestViewportHeight > $0 } ?? false
        let height = reservesHeight ? largestViewportHeight : min(self.documentHeight, limit)
        let size = NSSize(width: width, height: height)
        guard self.viewportSize != size else { return }
        self.viewportSize = size
        self.setFrameSize(size)
        self.invalidateIntrinsicContentSize()
        self.tile()
    }

    /// Resize and publish the selected content in one transaction, before either can paint alone.
    func adjustDocumentHeight(by delta: CGFloat, updateContent: @MainActor () -> Void) {
        self.updateDocumentHeight(self.documentHeight + delta, updateContent: updateContent)
    }

    func updateDocumentHeight(_ height: CGFloat, updateContent: @MainActor () -> Void = {}) {
        let height = max(1, ceil(height))
        guard self.documentHeight != height else {
            updateContent()
            return
        }
        self.window?.disableScreenUpdatesUntilFlush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            self.documentHeight = height
            self.maximumDocumentHeight = max(self.maximumDocumentHeight, height)
            self.updateSize(width: self.viewportSize.width, maximumHeight: self.maximumHeight)
            updateContent()
            self.resizeDocument(self.viewportSize.width, height)
            self.superview?.layoutSubtreeIfNeeded()
            self.window?.invalidateShadow()
        }
    }

    static func availableHeightBelowAnchor(for menu: NSMenu) -> CGFloat? {
        if let parent = menu.supermenu,
           let anchor = parent.items.first(where: { $0.submenu === menu })?.view,
           let window = anchor.window, window.isVisible,
           let screen = window.screen
        {
            let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            return max(1, anchorFrame.maxY - screen.visibleFrame.minY - 6)
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return nil }
        return max(1, pointer.y - screen.visibleFrame.minY - 6)
    }

    static func maximumHeight(for menu: NSMenu) -> CGFloat {
        var candidate: NSMenu? = menu
        while let current = candidate {
            if let screen = current.items.compactMap({ item -> NSScreen? in
                guard let window = item.view?.window, window.isVisible else { return nil }
                return window.screen
            }).first {
                return self.maximumHeight(on: screen)
            }
            candidate = current.supermenu
        }
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        return self.maximumHeight(on: pointerScreen)
    }

    private static func maximumHeight(on screen: NSScreen?) -> CGFloat {
        min(620, max(1, (screen?.visibleFrame.height ?? 860) * 0.72))
    }
}
