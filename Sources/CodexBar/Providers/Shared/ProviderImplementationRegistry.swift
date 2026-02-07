import CodexBarCore
import Foundation

enum ProviderImplementationRegistry {
    private final class Store: @unchecked Sendable {
        var ordered: [any ProviderImplementation] = []
        var byID: [UsageProvider: any ProviderImplementation] = [:]
    }

    private static let lock = NSLock()
    private static let store = Store()

    private static func makeImplementation(for provider: UsageProvider) -> (any ProviderImplementation) {
        switch provider {
        case .codex: CodexProviderImplementation()
        case .claude: ClaudeProviderImplementation()
        case .cursor: CursorProviderImplementation()
        case .opencode: OpenCodeProviderImplementation()
        case .factory: FactoryProviderImplementation()
        case .gemini: GeminiProviderImplementation()
        case .antigravity: AntigravityProviderImplementation()
        case .copilot: CopilotProviderImplementation()
        case .zai: ZaiProviderImplementation()
        case .minimax: MiniMaxProviderImplementation()
        case .kimi: KimiProviderImplementation()
        case .kiro: KiroProviderImplementation()
        case .vertexai: VertexAIProviderImplementation()
        case .augment: AugmentProviderImplementation()
        case .jetbrains: JetBrainsProviderImplementation()
        case .kimik2: KimiK2ProviderImplementation()
        case .amp: AmpProviderImplementation()
        case .synthetic: SyntheticProviderImplementation()
        case .warp: WarpProviderImplementation()
        }
    }

    private static let bootstrap: Void = {
        for provider in UsageProvider.allCases {
            _ = ProviderImplementationRegistry.register(makeImplementation(for: provider))
        }
    }()

    private static func ensureBootstrapped() {
        _ = self.bootstrap
    }

    @discardableResult
    static func register(_ implementation: any ProviderImplementation) -> any ProviderImplementation {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.store.byID[implementation.id] == nil {
            self.store.ordered.append(implementation)
        }
        self.store.byID[implementation.id] = implementation
        return implementation
    }

    static var all: [any ProviderImplementation] {
        self.ensureBootstrapped()
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.store.ordered
    }

    static func implementation(for id: UsageProvider) -> (any ProviderImplementation)? {
        self.ensureBootstrapped()
        if let found = self.store.byID[id] { return found }
        return self.all.first(where: { $0.id == id })
    }
}
