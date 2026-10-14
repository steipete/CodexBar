import Foundation
import Testing
@testable import CodexBar

struct HomebrewUpdateFailureTests {
    @Test(arguments: ["homebrew/cask-versions", "homebrew/homebrew-cask-versions"])
    func `known retired tap offers a fixed repair command only before installation`(tap: String) {
        let diagnostic = "Error: \(tap) does not exist! Run brew untap to remove it."
        let failure = HomebrewUpdateFailure(stage: .preparing, details: diagnostic)
        #expect(failure.repairCommand == "brew untap homebrew/cask-versions")
        #expect(failure.details == diagnostic)
        #expect(HomebrewUpdateFailure(stage: .installing, details: diagnostic).repairCommand == nil)
        #expect(HomebrewUpdateFailure(stage: .checking, details: diagnostic).repairCommand == nil)
    }

    @Test(arguments: [
        "Error: arbitrary/tap does not exist! Run brew untap arbitrary/tap to remove it.",
        "fatal: repository not found",
        "brew untap homebrew/cask-versions",
    ])
    func `unknown failures never invent a repair command`(diagnostic: String) {
        #expect(HomebrewUpdateFailure(stage: .preparing, details: diagnostic).repairCommand == nil)
    }

    @Test
    func `failure summary stays short while preserving the complete diagnostic`() {
        let diagnostic = String(repeating: "unrelated Homebrew output\n", count: 1000)
        let failure = HomebrewUpdateFailure(stage: .preparing, details: diagnostic)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(failure.summary == "Couldn’t prepare the update")
        }
        #expect(failure.localizedDescription == diagnostic)
    }

    @Test
    func `stale availability explains the version gap`() {
        let info = #"{"casks":[{"token":"codexbar","tap":"steipete/tap","version":"0.65.0","disabled":false}]}"#
        #expect(throws: HomebrewUpdateError.versionUnavailable(available: "0.65.0", requested: "0.66.0")) {
            try HomebrewUpgradeAvailability.verify(json: info, cask: .tap, targetVersion: "0.66.0")
        }
    }

    @Test
    func `recovery copy is translated in every supported language`() {
        let keys = [
            "Couldn’t check for updates", "Couldn’t prepare the update", "Couldn’t update CodexBar",
            "Remove the retired Homebrew source in Terminal, then retry.",
            "Check the details below, then try again.", "Copy repair command", "Retry",
        ]
        for language in AppLanguage.allCases where language != .system && language != .english {
            CodexBarLocalizationOverride.$appLanguage.withValue(language.rawValue) {
                for key in keys {
                    #expect(L(key) != key, "Untranslated \(language.rawValue): \(key)")
                }
            }
        }
    }
}
