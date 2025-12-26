import AppKit
import CodexBarCore

@MainActor
extension StatusItemController {
    /// Runs the provider-specific login flow.
    /// - Returns: Whether CodexBar should refresh after the flow completes.
    func runLoginFlow(provider: UsageProvider) async -> Bool {
        switch provider {
        case .codex:
            await self.runCodexLoginFlow()
            return true
        case .claude:
            await self.runClaudeLoginFlow()
            return true
        case .zai:
            return false
        case .gemini:
            await self.runGeminiLoginFlow()
            return false
        case .antigravity:
            await self.runAntigravityLoginFlow()
            return false
        case .cursor:
            await self.runCursorLoginFlow()
            return true
        case .factory:
            return await self.runFactoryLoginFlow()
        }
    }
}
