import Testing
@testable import CodexBarCore

struct OpenRouterProviderDescriptorTests {
    @Test
    func `usage dashboard opens Activity rather than credit settings`() {
        #expect(OpenRouterProviderDescriptor.descriptor.metadata.dashboardURL == "https://openrouter.ai/activity")
    }
}
