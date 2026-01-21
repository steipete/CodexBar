import KeyboardShortcuts
import Testing

@MainActor
@Suite struct KeyboardShortcutsBundleTests {
    @Test func recorderInitializesWithoutCrashing() {
        _ = KeyboardShortcuts.RecorderCocoa(for: .init("test.keyboardshortcuts.bundle"))
    }
}
