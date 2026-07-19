import Testing
@testable import CodexBar

@Suite(.serialized)
struct LoginNotificationLogicTests {
    @Test
    func `login success notification copy follows Traditional Chinese app language`() {
        Self.withAppLanguage("zh-Hant") {
            let copy = LoginNotificationLogic.notificationCopy(providerName: "Codex")

            #expect(copy.title == "Codex 登入成功")
            #expect(copy.body == "你可以回到 App；認證已完成。")
        }
    }

    private static func withAppLanguage(_ language: String, perform body: () -> Void) {
        CodexBarLocalizationOverride.$appLanguage.withValue(language, operation: body)
    }
}
