import Foundation

enum LoadingPattern: String, CaseIterable, Identifiable {
    case knightRider
    case cylon
    case outsideIn
    case race
    case pulse
    case unbraid

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .knightRider: "Knight Rider"
        case .cylon: "Cylon"
        case .outsideIn: "Outside-In"
        case .race: "Race"
        case .pulse: "Pulse"
        case .unbraid: "Unbraid (logo → bars)"
        }
    }

    /// Secondary offset so the lower bar moves differently.
    var secondaryOffset: Double {
        switch self {
        case .knightRider: .pi
        case .cylon: .pi / 2
        case .outsideIn: .pi
        case .race: .pi / 3
        case .pulse: .pi / 2
        case .unbraid: .pi / 2
        }
    }

    func value(phase: Double) -> Double {
        let v: Double
        switch self {
        case .knightRider:
            v = 0.5 + 0.5 * sin(phase) // ping-pong
        case .cylon:
            let t = phase.truncatingRemainder(dividingBy: .pi * 2) / (.pi * 2)
            v = t // sawtooth 0→1
        case .outsideIn:
            v = abs(cos(phase)) // high at edges, dip center
        case .race:
            let t = (phase * 1.2).truncatingRemainder(dividingBy: .pi * 2) / (.pi * 2)
            v = t
        case .pulse:
            v = 0.4 + 0.6 * (0.5 + 0.5 * sin(phase)) // 40–100%
        case .unbraid:
            v = 0.5 + 0.5 * sin(phase) // smooth 0→1 for morph
        }
        return max(0, min(v * 100, 100))
    }
}

extension Notification.Name {
    static let codexbarDebugReplayAllAnimations = Notification.Name("codexbarDebugReplayAllAnimations")
}
