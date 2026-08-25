import AppKit
import Foundation
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

    @Test func `open menu recorder follows selected app language`() {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test.keyboardshortcuts.localization"))
        let coordinator = OpenMenuShortcutRecorder.Coordinator()

        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            coordinator.attach(to: recorder)
            #expect(recorder.placeholderString == "Record Shortcut")

            NotificationCenter.default.post(
                name: NSControl.textDidBeginEditingNotification,
                object: recorder)
            #expect(recorder.placeholderString == "Press Shortcut")

            NotificationCenter.default.post(
                name: NSControl.textDidEndEditingNotification,
                object: recorder)
            #expect(recorder.placeholderString == "Record Shortcut")
        }

        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            coordinator.attach(to: recorder)
            #expect(recorder.placeholderString == "设置快捷键")

            NotificationCenter.default.post(
                name: NSControl.textDidBeginEditingNotification,
                object: recorder)
            #expect(recorder.placeholderString == "按下快捷键")
        }
    }

    @Test func `localized prompts survive later recorder lifecycle writes`() async {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("test.keyboardshortcuts.lifecycle"))
        let coordinator = OpenMenuShortcutRecorder.Coordinator()

        await CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            coordinator.attach(to: recorder)

            NotificationCenter.default.post(
                name: NSControl.textDidBeginEditingNotification,
                object: recorder)
            recorder.placeholderString = "Dependency recording prompt"
            await Task.yield()
            #expect(recorder.placeholderString == "按下快捷键")

            let notification = Notification(
                name: NSControl.textDidEndEditingNotification,
                object: recorder)
            NotificationCenter.default.post(notification)
            recorder.controlTextDidEndEditing(notification)
            await Task.yield()
            #expect(recorder.placeholderString == "设置快捷键")
        }
    }
}
