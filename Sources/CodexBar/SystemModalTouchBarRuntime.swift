import AppKit

/// Bridges the undocumented `NSTouchBar`/`DFRFoundation` system-modal presentation API
/// (used by MTMR, Pock, and others to keep custom Touch Bar content visible outside the
/// frontmost app) via the Objective-C runtime — no private-framework linking required.
///
/// ponytail: reverse-engineered from OSS precedent (Toxblh/MTMR), not Apple docs. Ceiling:
/// selector names/signatures can change across macOS versions; every call here is a no-op
/// (guarded by optional lookups) rather than a crash if the symbol disappears.
enum SystemModalTouchBarRuntime {
    private typealias PresentPlacementFn =
        @convention(c) (AnyClass, Selector, NSTouchBar?, Int64, NSTouchBarItem.Identifier?) -> Void
    private typealias DismissFn = @convention(c) (AnyClass, Selector, NSTouchBar?) -> Void
    private typealias CloseBoxFn = @convention(c) (Bool) -> Void

    static func presentSystemModal(
        _ touchBar: NSTouchBar,
        placement: Int64,
        systemTrayItemIdentifier identifier: NSTouchBarItem.Identifier?)
    {
        let selector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else { return }
        let fn = unsafeBitCast(method_getImplementation(method), to: PresentPlacementFn.self)
        fn(NSTouchBar.self, selector, touchBar, placement, identifier)
    }

    static func dismissSystemModal(_ touchBar: NSTouchBar) {
        let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else { return }
        let fn = unsafeBitCast(method_getImplementation(method), to: DismissFn.self)
        fn(NSTouchBar.self, selector, touchBar)
    }

    static func setCloseBoxVisibleWhenFrontmost(_ visible: Bool) {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
                RTLD_NOW),
            let symbol = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost")
        else { return }
        let fn = unsafeBitCast(symbol, to: CloseBoxFn.self)
        fn(visible)
    }
}
