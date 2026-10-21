import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct LocalizationFormattingTests {
    @Test
    func `Arabic formatted integers use the selected resource number system`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("ar") {
            #expect(L("%d%% in reserve", 12) == "١٢% في الاحتياط")
            #expect(L("%d%% in reserve", 12).contains(codexBarLocalizedInteger(12)))
        }
    }

    @Test(arguments: ["ru", "pl", "ar"])
    func `generic formatter follows the plural rules of the selected resources`(language: String) {
        CodexBarLocalizationOverride.$appLanguage.withValue(language) {
            let key = "Weekly can run out ≈%d windows early"
            for count in [0, 1, 2, 5, 21, 101] {
                #expect(L(key, count) == String(
                    format: L(key), locale: codexBarLocalizedResourceLocale(), arguments: [count]))
            }
        }
    }

    @Test(arguments: [("ar", true), ("fa", true), ("en", false), ("zh-Hans", false), ("zz", false)])
    func `layout direction follows the resolved resource including fallback`(language: String, rtl: Bool) {
        CodexBarLocalizationOverride.$appLanguage.withValue(language) {
            #expect(codexBarLocalizedLayoutDirection() == (rtl ? .rightToLeft : .leftToRight))
        }
    }

    @Test
    func `SwiftUI localization modifier overrides the inherited system environment`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("ar") {
            let capture = EnvironmentCapture()
            let renderer = ImageRenderer(content: EnvironmentProbe(capture: capture)
                .codexBarLocalized()
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.layoutDirection, .leftToRight))
            _ = try #require(renderer.nsImage)
            #expect(capture.direction == .rightToLeft)
            #expect(capture.locale?.language.languageCode?.identifier == "ar")
        }
    }

    @MainActor
    private final class EnvironmentCapture {
        var locale: Locale?
        var direction: LayoutDirection?
    }

    private struct EnvironmentProbe: View {
        @Environment(\.locale) private var locale
        @Environment(\.layoutDirection) private var direction
        let capture: EnvironmentCapture

        var body: some View {
            self.capture.locale = self.locale
            self.capture.direction = self.direction
            return Text(verbatim: "fixture").frame(width: 80, height: 30)
        }
    }
}
