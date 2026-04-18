import KeyboardShortcuts
import Testing

@MainActor
struct KeyboardShortcutsBundleTests {
    @Test func `recorder initializes without crashing`() {
        _ = KeyboardShortcuts.RecorderCocoa(for: .init("test.keyboardshortcuts.bundle"))
    }
}
