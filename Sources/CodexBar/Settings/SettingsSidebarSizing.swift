import SwiftUI

/// Share the saved width with the legacy sidebar while letting the native divider handle dragging.
struct SettingsSidebarSizing: ViewModifier {
    @Binding var width: Double

    func body(content: Content) -> some View {
        content
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
