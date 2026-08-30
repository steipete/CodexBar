import AppKit

/// Geometry helpers for the built-in display's camera housing.
enum NotchGeometry {
    static func expandedContentFrame(screenFrame: CGRect, notchRect: CGRect, contentSize: CGSize) -> CGRect {
        let width = min(contentSize.width, max(1, screenFrame.width - 16))
        let top = min(notchRect.minY, screenFrame.maxY)
        let availableHeight = max(0, top - screenFrame.minY)
        let height = min(contentSize.height, screenFrame.height * 0.9, availableHeight)
        let x = min(max(notchRect.midX - width / 2, screenFrame.minX), screenFrame.maxX - width)
        let y = top - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Computes the camera housing rectangle in global screen coordinates.
    static func notchRect(
        screenFrame: CGRect,
        topInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?) -> CGRect?
    {
        guard topInset > 0,
              let auxiliaryTopLeftWidth,
              let auxiliaryTopRightWidth
        else { return nil }

        let width = screenFrame.width - auxiliaryTopLeftWidth - auxiliaryTopRightWidth
        guard width > 0 else { return nil }

        return CGRect(
            x: screenFrame.minX + auxiliaryTopLeftWidth,
            y: screenFrame.maxY - topInset,
            width: width,
            height: topInset)
    }

    @MainActor
    static func notchRect(for screen: NSScreen) -> CGRect? {
        self.notchRect(
            screenFrame: screen.frame,
            topInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width)
    }

    @MainActor
    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first(where: { self.notchRect(for: $0) != nil })
    }

    @MainActor
    static func hasNotchedScreen() -> Bool {
        self.notchedScreen() != nil
    }
}
