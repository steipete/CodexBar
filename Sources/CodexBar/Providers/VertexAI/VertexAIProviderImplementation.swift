import CodexBarCore
import Foundation

struct VertexAIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .vertexai
    let supportsLoginFlow: Bool = true

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runVertexAILoginFlow()
        return false
    }
}
