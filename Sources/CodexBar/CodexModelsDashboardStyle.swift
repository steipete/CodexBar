import CodexBarCore
import SwiftUI

enum CodexModelsDashboardTokens {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let xLarge: CGFloat = 16
        static let outer: CGFloat = 20
        static let xxLarge: CGFloat = 24
    }

    enum Radius {
        static let surface: CGFloat = 10
        static let chartBar: CGFloat = 4
        static let tooltip: CGFloat = 6
    }

    enum Width {
        static let wide: CGFloat = 1280
        static let medium: CGFloat = 960
        static let inspectorMinimum: CGFloat = 280
        static let inspectorIdeal: CGFloat = 320
        static let inspectorMaximum: CGFloat = 420
        static let wideAnalysisTrailing: CGFloat = 590
        static let mediumConcentration: CGFloat = 480
    }

    enum Height {
        static let wideSummary: CGFloat = 112
        static let mediumSummaryCell: CGFloat = 100
        static let compactSummaryCell: CGFloat = 88
        static let wideAnalyticsHeader: CGFloat = 54
        static let wideAnalysisBody: CGFloat = 334
        static let wideTimeline: CGFloat = 200
        static let wideConcentration: CGFloat = 134
        static let mediumRanking: CGFloat = 340
        static let mediumAnalysisLower: CGFloat = 212
        static let wideTableToolbar: CGFloat = 56
        static let table: CGFloat = 300
    }

    static func sectionSpacing(for layout: CodexModelsDashboardModel.Layout) -> CGFloat {
        layout == .wide ? Spacing.medium : Spacing.xLarge
    }
}

private struct CodexModelsDashboardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: CodexModelsDashboardTokens.Radius.surface, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CodexModelsDashboardTokens.Radius.surface, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }
}

extension View {
    func codexModelsDashboardSurface() -> some View {
        self.modifier(CodexModelsDashboardSurface())
    }
}

struct CodexModelsTableColumnProfile: Equatable {
    let showsSessionReferences: Bool
    let showsDelta: Bool
    let showsKnownCost: Bool
    let showsColumnMenu: Bool

    static func resolve(
        layout: CodexModelsDashboardModel.Layout,
        metric: CodexModelsMetric,
        showsEstimatedCost: Bool) -> Self
    {
        let showsKnownCost = showsEstimatedCost && metric != .knownCost
        switch layout {
        case .wide:
            return Self(
                showsSessionReferences: true,
                showsDelta: true,
                showsKnownCost: showsKnownCost,
                showsColumnMenu: true)
        case .medium:
            return Self(
                showsSessionReferences: false,
                showsDelta: true,
                showsKnownCost: showsKnownCost,
                showsColumnMenu: false)
        case .compact:
            return Self(
                showsSessionReferences: false,
                showsDelta: false,
                showsKnownCost: showsKnownCost,
                showsColumnMenu: false)
        }
    }
}

enum CodexModelsFreshnessState: Equatable {
    case current
    case refreshing
    case stale(String)
}

enum CodexModelsSelectionPresentation: Equatable {
    case inspector
    case sheet

    static func resolve(layout: CodexModelsDashboardModel.Layout) -> Self {
        layout == .compact ? .sheet : .inspector
    }
}
