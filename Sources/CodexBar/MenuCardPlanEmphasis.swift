import SwiftUI

extension UsageMenuCardView.Model {
    /// Visual weight for a card's `planText`.
    ///
    /// Most cards use it for a plan name, where plain secondary text is right.
    /// Multi-account cards use it for account state instead, and there the
    /// current account has to be identifiable at a glance among sibling cards
    /// that otherwise look identical.
    enum PlanEmphasis {
        /// Ordinary secondary text (a plan name, or an offered action).
        case none
        /// The account this provider is currently using.
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
