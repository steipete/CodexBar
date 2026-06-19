import KeyboardShortcuts
import Testing
@testable import CodexBar

@MainActor
struct KeyboardShortcutsBundleTests {
    @Test func `recorder initializes without crashing`() {
        _ = KeyboardShortcuts.RecorderCocoa(for: .init("test.keyboardshortcuts.bundle"))
    }

    @Test func `open menu recorder expands beyond dependency intrinsic width`() {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test.keyboardshortcuts.width"))
        let size = OpenMenuShortcutRecorder.fittedSize(intrinsicHeight: recorder.intrinsicContentSize.height)

        #expect(size.width == OpenMenuShortcutRecorder.preferredWidth)
        #expect(size.width > recorder.intrinsicContentSize.width)
        #expect(size.height == recorder.intrinsicContentSize.height)
    }
}
