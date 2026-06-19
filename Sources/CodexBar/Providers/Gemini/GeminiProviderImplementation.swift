import CodexBarCore
import Foundation

struct GeminiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .gemini
    let supportsLoginFlow: Bool = true

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runGeminiLoginFlow()
        return false
    }
}
