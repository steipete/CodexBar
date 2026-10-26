import CoreGraphics

enum UsageMenuCardLayout {
    static let horizontalPadding: CGFloat = 20
    static let headerOnlyVerticalPadding: CGFloat = 6
    static let headerContentSpacing: CGFloat = 6
    static let sectionTopPadding: CGFloat = 6
    static let usageSectionTopPadding: CGFloat = 10
    static let sectionBottomPadding: CGFloat = 6
    static let headerLineSpacing: CGFloat = 4
    static let headerColumnSpacing: CGFloat = 12

    static var postHeaderDividerContentSpacing: CGFloat {
        // Reproduces Overview's header-bottom + usage-top gap so full cards align.
        sectionBottomPadding + usageSectionTopPadding
    }
}
