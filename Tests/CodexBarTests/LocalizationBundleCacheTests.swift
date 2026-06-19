import Foundation
import Testing
@testable import CodexBar

/// Regression coverage for the localized-bundle caching added for #1347.
///
/// The cache is process-global and these tests run in a parallel suite, so identity (`===`) assertions
/// would race against any other test that resolves a different language. Instead these assert the
/// concurrency-safe property that matters for correctness: every call resolves to the right `.lproj`
/// regardless of what is currently cached, so a language switch (and switch-back) is always honored and
/// the cache can never serve a stale localization.
struct LocalizationBundleCacheTests {
    @Test
    func `resolves the correct lproj per language and re-resolves on switch`() {
        resetCodexBarLocalizationCacheForTesting()

        let fr = CodexBarLocalizationOverride.$appLanguage.withValue("fr") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(fr.bundleURL.lastPathComponent == "fr.lproj")

        // Switching language must re-resolve rather than return the cached French bundle.
        let es = CodexBarLocalizationOverride.$appLanguage.withValue("es") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(es.bundleURL.lastPathComponent == "es.lproj")

        // Switching back must still produce the French bundle (cache key is the language).
        let frAgain = CodexBarLocalizationOverride.$appLanguage.withValue("fr") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(frAgain.bundleURL.lastPathComponent == "fr.lproj")
    }

    @Test
    func `repeated same-language calls keep resolving the same lproj`() {
        resetCodexBarLocalizationCacheForTesting()

        for _ in 0..<5 {
            let bundle = CodexBarLocalizationOverride.$appLanguage.withValue("es") {
                codexBarLocalizedBundleForTesting()
            }
            #expect(bundle.bundleURL.lastPathComponent == "es.lproj")
        }
    }

    @Test
    func `unknown language falls back to en lproj`() {
        resetCodexBarLocalizationCacheForTesting()

        let bundle = CodexBarLocalizationOverride.$appLanguage.withValue("zz-unknown") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(bundle.bundleURL.lastPathComponent == "en.lproj")
    }

    @Test
    func `resolution survives an explicit cache reset`() {
        let first = CodexBarLocalizationOverride.$appLanguage.withValue("uk") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(first.bundleURL.lastPathComponent == "uk.lproj")

        resetCodexBarLocalizationCacheForTesting()

        let afterReset = CodexBarLocalizationOverride.$appLanguage.withValue("uk") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(afterReset.bundleURL.lastPathComponent == "uk.lproj")
    }
}
