import AppKit
import SwiftUI

/// Share the saved width with the legacy sidebar while letting the native divider handle dragging.
struct SettingsSidebarSizing: ViewModifier {
    @Binding var width: Double

    func body(content: Content) -> some View {
        content
            .background {
                SettingsSidebarCollapseGuard()
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { newWidth in
                // Ignore transient zero/undersized measurements while the split view is being attached.
                guard newWidth >= SettingsPane.sidebarMinWidth,
                      newWidth <= SettingsPane.sidebarMaxWidth,
                      abs(self.width - newWidth) > 0.5 else { return }
                self.width = newWidth
            }
            // Keep this last so the column preference reaches NavigationSplitView.
            .navigationSplitViewColumnWidth(
                min: SettingsPane.sidebarMinWidth,
                ideal: min(max(self.width, SettingsPane.sidebarMinWidth), SettingsPane.sidebarMaxWidth),
                max: SettingsPane.sidebarMaxWidth)
    }
}

/// SwiftUI's column minimum still allows dragging a sidebar closed. Disable that AppKit behavior
/// on this column without replacing the split view's delegate or affecting other split views.
private struct SettingsSidebarCollapseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsSidebarCollapseGuardView {
        SettingsSidebarCollapseGuardView()
    }

    func updateNSView(_ nsView: SettingsSidebarCollapseGuardView, context: Context) {
        nsView.preventCollapse()
    }
}

final class SettingsSidebarCollapseGuardView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.preventCollapse()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.preventCollapse()
    }

    override func layout() {
        super.layout()
        self.preventCollapse()
    }

    func preventCollapse() {
        var ancestor = self.superview
        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController,
               let sidebar = controller.splitViewItems.first(where: {
                   $0.behavior == .sidebar && self.isDescendant(of: $0.viewController.view)
               })
            {
                if sidebar.canCollapse {
                    sidebar.canCollapse = false
                }
                return
            }
            ancestor = view.superview
        }
    }
}
