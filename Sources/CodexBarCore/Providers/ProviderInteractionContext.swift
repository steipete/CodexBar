import Foundation

public enum ProviderInteraction: Sendable, Equatable {
    case background
    case userInitiated
}

public enum ProviderInteractionContext {
    @TaskLocal public static var current: ProviderInteraction = .background
}
