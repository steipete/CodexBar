import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct WorkBuddyAppSettingsTests {
    @Test
    func `WorkBuddy user agent is visible only for manual cookies and stays in its config`() throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-workbuddy-user-agent")
        let implementation = try #require(ProviderCatalog.implementation(for: .workbuddy))
        let context = fixture.settingsContext(provider: .workbuddy)
        let picker = try #require(implementation.settingsPickers(context: context).first)
        let field = try #require(implementation.settingsFields(context: context)
            .first { $0.id == "workbuddy-user-agent" })
        picker.binding.wrappedValue = "auto"
        #expect(field.isVisible?() == false)
        picker.binding.wrappedValue = "manual"
        #expect(field.isVisible?() == true)
        #expect(field.kind == .plain)
        field.binding.wrappedValue = "Mozilla/5.0 Edge fixture"
        #expect(fixture.settings.providerConfig(for: .workbuddy)?.workBuddyUserAgent == "Mozilla/5.0 Edge fixture")
        #expect(fixture.settings.providerConfig(for: .cursor)?.workBuddyUserAgent == nil)
        let contribution = try #require(implementation.settingsSnapshot(context: .init(
            settings: fixture.settings, tokenOverride: nil)))
        let snapshot = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(snapshot.workbuddy?.manualUserAgent == "Mozilla/5.0 Edge fixture")
        #expect(snapshot.workbuddy?.cookies.cookieSource == .manual)
        field.binding.wrappedValue = ""
        #expect(fixture.settings.providerConfig(for: .workbuddy)?.workBuddyUserAgent == nil)
        picker.binding.wrappedValue = "off"
        #expect(field.isVisible?() == false)
    }
}
