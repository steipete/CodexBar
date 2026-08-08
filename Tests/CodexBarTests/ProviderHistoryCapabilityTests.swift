import CodexBarCore
import Testing

struct ProviderHistoryCapabilityTests {
    @Test
    func `always tracked plan utilization providers are descriptor owned`() {
        let alwaysTracked = Set(ProviderDescriptorRegistry.all.compactMap { descriptor in
            descriptor.history.alwaysTracksPlanUtilization ? descriptor.id : nil
        })

        #expect(alwaysTracked == [.codex, .claude, .antigravity, .opencodego])
    }
}
