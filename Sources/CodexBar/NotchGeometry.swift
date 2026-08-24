import AppKit

/// Geometry helpers for the built-in display's camera housing.
enum NotchGeometry {
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
