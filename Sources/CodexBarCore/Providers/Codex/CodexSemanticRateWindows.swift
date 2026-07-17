import Foundation

public enum CodexSemanticRateWindowRole: String, Hashable, Sendable {
    case session
    case weekly
}

public struct CodexSemanticRateWindows: Sendable {
    public let sourceOrder: [CodexSemanticRateWindowRole]

    private let windowsByRole: [CodexSemanticRateWindowRole: RateWindow]

    public init(snapshot: UsageSnapshot) {
        let slottedWindows = [
            Self.classify(snapshot.primary, fallback: .session),
            Self.classify(snapshot.secondary, fallback: .weekly),
        ].compactMap(\.self)

        var windowsByRole: [CodexSemanticRateWindowRole: RateWindow] = [:]
        var sourceOrder: [CodexSemanticRateWindowRole] = []
        for (role, window) in slottedWindows {
            windowsByRole[role] = window
            if !sourceOrder.contains(role) {
                sourceOrder.append(role)
            }
        }
        self.windowsByRole = windowsByRole
        self.sourceOrder = sourceOrder
    }

    public func window(for role: CodexSemanticRateWindowRole) -> RateWindow? {
        self.windowsByRole[role]
    }

    private static func classify(
        _ window: RateWindow?,
        fallback: CodexSemanticRateWindowRole) -> (CodexSemanticRateWindowRole, RateWindow)?
    {
        guard let window else { return nil }
        let role: CodexSemanticRateWindowRole = switch window.windowMinutes {
        case 300:
            .session
        case 10080:
            .weekly
        default:
            fallback
        }
        return (role, window)
    }
}
