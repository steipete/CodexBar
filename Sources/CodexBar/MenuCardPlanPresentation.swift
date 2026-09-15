import SwiftUI

extension UsageMenuCardView.Model {
    enum PlanOverride {
        case automatic
        case label(String?)
    }

    enum PlanEmphasis {
        case none
        case active

        func color(highlighted: Bool) -> Color {
            switch self {
            case .none: MenuHighlightStyle.secondary(highlighted)
            case .active: MenuHighlightStyle.accent(highlighted)
            }
        }

        var isEmphasized: Bool {
            self != .none
        }
    }
}
