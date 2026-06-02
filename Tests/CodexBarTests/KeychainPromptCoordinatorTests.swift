import Foundation
import Testing
@testable import CodexBar

/// Tests for the dev-build self-diagnosis helper in `KeychainPromptCoordinator`.
///
/// The helper is intentionally side-effect-free: a pure function returns a
/// warning string when the running binary looks like a SwiftPM dev build or
/// is ad-hoc signed, and `nil` otherwise. A separate one-shot startup function
/// disables keychain access for that process and gates emission of the warning
/// to once per process.
///
/// The pure function lives next to `KeychainPromptCoordinator` because the
/// detection is conceptually part of the prompt-coordination subsystem, not
/// the auth/OAuth code path.
struct KeychainPromptCoordinatorTests {
    // MARK: - Pure function: adHocDevBuildHint(bundlePath:executablePath:isAdHocSigned:)

    @Test
    func `adHocDevBuildHint returns nil for properly-signed release app`() {
        // /Applications/CodexBar.app — Developer ID signed, no .build path, not ad-hoc.
        let result = KeychainPromptCoordinator.adHocDevBuildHint(
            bundlePath: "/Applications/CodexBar.app",
            executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar",
            isAdHocSigned: false)
        #expect(result == nil, "release app should not trigger the dev-build hint")
    }

    @Test
    func `adHocDevBuildHint returns warning for SwiftPM dev build path even when not ad-hoc`() {
        // Even if a local-dev build is signed with a stable Developer ID
        // (per Scripts/compile_and_run.sh), the .build/debug/ path itself is
        // a strong signal the user is in local-dev mode and should be steered
        // to the workaround doc.
        let result = KeychainPromptCoordinator.adHocDevBuildHint(
            bundlePath: "/Users/me/Developer/codexbar/.build/arm64-apple-macosx/debug/CodexBar",
            executablePath: "/Users/me/Developer/codexbar/.build/arm64-apple-macosx/debug/CodexBar",
            isAdHocSigned: false)
        #expect(result != nil, "SwiftPM dev build path should trigger the hint even when signed with a stable identity")
        #expect(
            result?.contains("LOCAL_DEV_BUILD") == true || result?.contains(".build/") == true,
            "hint should point to the dev-build detection cause or the doc")
    }

    @Test
    func `adHocDevBuildHint returns warning for ad-hoc signed binary at any path`() {
        // A user could move a properly-named bundle outside /Applications.
        // The ad-hoc check should still fire.
        let result = KeychainPromptCoordinator.adHocDevBuildHint(
            bundlePath: "/Users/me/Desktop/CodexBar.app",
            executablePath: "/Users/me/Desktop/CodexBar.app/Contents/MacOS/CodexBar",
            isAdHocSigned: true)
        #expect(result != nil, "ad-hoc signed binary should trigger the hint regardless of path")
    }

    @Test
    func `adHocDevBuildHint returns nil when bundlePath is empty and not ad-hoc`() {
        // Defensive: empty bundle path is not a dev build.
        let result = KeychainPromptCoordinator.adHocDevBuildHint(
            bundlePath: "",
            executablePath: "",
            isAdHocSigned: false)
        #expect(result == nil)
    }

    @Test
    func `adHocDevBuildHint warning text includes actionable workarounds`() {
        // The warning must point the contributor at concrete next steps, not
        // just diagnose the problem. This is the user-facing value of the hint.
        let result = KeychainPromptCoordinator.adHocDevBuildHint(
            bundlePath: "/Users/me/Developer/codexbar/.build/debug/CodexBar",
            executablePath: "/Users/me/Developer/codexbar/.build/debug/CodexBar",
            isAdHocSigned: true)
        #expect(result != nil)
        // Must mention at least one workaround
        let hasReleaseAppRef = result?.contains("/Applications/CodexBar.app") == true
        let hasScriptRef = result?.contains("compile_and_run.sh") == true
        #expect(
            hasReleaseAppRef || hasScriptRef,
            "warning should mention at least one workaround")
        #expect(
            result?.contains("disabled keychain access for this process") == true,
            "warning should make it clear CodexBar avoided the prompt loop")
    }
}
