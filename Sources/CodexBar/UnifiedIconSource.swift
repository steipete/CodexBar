import SwiftUI

enum UnifiedIconSource: String, CaseIterable, Sendable {
    case currentSelection
    case highestUsage
    case frontmostApp
    case allProviders

    /// Sources that read across the Overview subset instead of following one selected provider.
    var readsOverviewProviders: Bool {
        self == .highestUsage || self == .allProviders
    }

    var label: String {
        switch self {
        case .currentSelection: L("merged_icon_source_current_selection")
        case .highestUsage: L("merged_icon_source_highest_usage")
        case .frontmostApp: L("merged_icon_source_frontmost_app")
        case .allProviders: L("merged_icon_source_all_providers")
        }
    }
}

struct UnifiedIconSourcePicker: View {
    @Binding var selection: UnifiedIconSource

    var body: some View {
        SettingsMenuPicker(
            selection: self.$selection,
            options: MenuBarSettingsMenuOptions.unifiedIconSources,
            label: {
                SettingsRowLabel(
                    L("merged_icon_source_title"),
                    subtitle: self.selection == .allProviders
                        ? L("merged_icon_source_all_providers_subtitle")
                        : L("merged_icon_source_subtitle"))
            },
            optionLabel: { Text($0.label) })
    }
}
