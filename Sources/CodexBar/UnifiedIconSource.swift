import SwiftUI

enum UnifiedIconSource: String, CaseIterable, Sendable {
    case currentSelection
    case highestUsage
    case frontmostApp

    var label: String {
        switch self {
        case .currentSelection: L("merged_icon_source_current_selection")
        case .highestUsage: L("merged_icon_source_highest_usage")
        case .frontmostApp: L("merged_icon_source_frontmost_app")
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
                SettingsRowLabel(L("merged_icon_source_title"), subtitle: L("merged_icon_source_subtitle"))
            },
            optionLabel: { Text($0.label) })
    }
}
