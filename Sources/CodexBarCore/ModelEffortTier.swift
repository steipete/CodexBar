import Foundation

/// How much compute a model spends per request, read from its public model id.
///
/// Size words win over effort words, so `o4-mini-high` is fast: the model class sets the cost, the
/// effort suffix only tunes it. Ids with neither (Sonnet, `gpt-5`, `gpt-5-codex`) are standard.
/// Reasoning effort recorded per turn is not part of the cost history these rows come from, so a
/// GPT row reads as high only when its id says so (`-high`, `-max`, `-pro`).
public enum ModelEffortTier: String, CaseIterable, Sendable, Codable, Comparable {
    case high
    case standard
    case fast

    private static let fastWords: Set<String> = [
        "haiku", "mini", "nano", "flash", "lite", "small", "fast", "low", "minimal", "instant",
    ]
    private static let highWords: Set<String> = [
        "opus", "max", "pro", "high", "xhigh", "ultra", "o1", "o3",
    ]

    public static func classify(_ modelName: String) -> ModelEffortTier {
        let words = Set(modelName.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !words.isDisjoint(with: self.fastWords) { return .fast }
        if !words.isDisjoint(with: self.highWords) { return .high }
        return .standard
    }

    public static func < (lhs: ModelEffortTier, rhs: ModelEffortTier) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .high: 0
        case .standard: 1
        case .fast: 2
        }
    }
}
