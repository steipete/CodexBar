import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct GladiaProviderTests {
    @Test
    func `standard settings persist the API key and detect availability`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "GladiaProviderTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .gladia))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .gladia))
        let field = try #require(fields.first)
        #expect(fields.count == 1)
        #expect(field.kind == .secure)
        #expect(field.title == "API key")
        #expect(ProviderSelection(argument: "GLADIA")?.asList == [.gladia])
        #expect(!implementation.isAvailable(context: .init(
            provider: .gladia, settings: fixture.settings, environment: [:])))
        field.binding.wrappedValue = "gladia-fixture"
        #expect(fixture.settings[providerConfig: .gladia, field: .apiKey] == "gladia-fixture")
        #expect(implementation.isAvailable(context: .init(
            provider: .gladia, settings: fixture.settings, environment: [:])))
    }

    @Test
    func `usage labels localize while durations stay canonical`() throws {
        let details = try [ProviderDetailSection(title: "This month", rows: [
            .init(label: "Billed audio", value: "1.9 h"),
            .init(label: "Pre-recorded", value: "1.7 h"),
            .init(label: "Transcriptions", value: "3"),
        ])]
        CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            let localized = UsageMenuCardView.Model.localizedProviderDetails(details, provider: .gladia)
            #expect(localized.first?.rows.map(\.label) == [
                "Abgerechnetes Audio",
                "Vorab aufgezeichnet",
                "Transkriptionen",
            ])
            #expect(localized.first?.rows.map(\.value) == ["1.9 h", "1.7 h", "3"])
        }
    }
}
