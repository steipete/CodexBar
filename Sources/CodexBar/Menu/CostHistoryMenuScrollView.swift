import AppKit
import SwiftUI

/// Keep the native menu row on screen; only the chart document scrolls when history is tall.
@MainActor
final class CostHistoryMenuScrollView: NSScrollView {
    private let measureDocument: (CGFloat) -> CGFloat
    private var maximumHeight: CGFloat = 620
    private var measuredWidth: CGFloat?
    private var documentHeight: CGFloat = 1
    private var viewportSize = NSSize(width: 1, height: 1)

    init(hosting: MenuHostingView<some View>, width: CGFloat, maximumHeight: CGFloat) {
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

    func updateSize(width: CGFloat, maximumHeight: CGFloat) {
        self.maximumHeight = maximumHeight
        if self.measuredWidth != width {
            self.documentHeight = max(1, ceil(self.measureDocument(width)))
            self.measuredWidth = width
        }
        let size = NSSize(width: width, height: min(self.documentHeight, max(1, maximumHeight)))
        guard self.viewportSize != size else { return }
        self.viewportSize = size
        self.setFrameSize(size)
        self.invalidateIntrinsicContentSize()
        self.tile()
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
