import CodexBarCore
import Foundation

enum ProviderImplementationRegistry {
    private final class Store: @unchecked Sendable {
        var ordered: [any ProviderImplementation] = []
        var byID: [UsageProvider: any ProviderImplementation] = [:]
    }

    private static let lock = NSLock()
    private static let store = Store()
    private static let bootstrap: Void = {
        _ = ProviderImplementationRegistry.register(CodexProviderImplementation())
        _ = ProviderImplementationRegistry.register(ClaudeProviderImplementation())
        _ = ProviderImplementationRegistry.register(FactoryProviderImplementation())
        _ = ProviderImplementationRegistry.register(ZaiProviderImplementation())
        _ = ProviderImplementationRegistry.register(MiniMaxProviderImplementation())
        _ = ProviderImplementationRegistry.register(AugmentProviderImplementation())
        _ = ProviderImplementationRegistry.register(CursorProviderImplementation())
        _ = ProviderImplementationRegistry.register(GeminiProviderImplementation())
        _ = ProviderImplementationRegistry.register(AntigravityProviderImplementation())
        _ = ProviderImplementationRegistry.register(CopilotProviderImplementation())
        _ = ProviderImplementationRegistry.register(KiroProviderImplementation())
        _ = ProviderImplementationRegistry.register(VertexAIProviderImplementation())
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
