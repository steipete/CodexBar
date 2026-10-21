import Testing
@preconcurrency import UserNotifications
@testable import CodexBar

@MainActor
struct UpdateNotificationActionTests {
    @Test
    func `clicking an update notice opens update settings without installing`() {
        var openCount = 0
        let notifications = AppNotifications(centerProvider: {
            Issue.record("Tests must not access the system notification center")
            fatalError("Unexpected notification center access")
        })
        notifications.configureUpdateAction { openCount += 1 }
        notifications.handleResponse(
            categoryIdentifier: AppNotifications.updateCategoryIdentifier,
            actionIdentifier: UNNotificationDefaultActionIdentifier)
        #expect(openCount == 1)
    }

    @Test
    func `dismissal and other notification types do not open update settings`() {
        var openCount = 0
        let notifications = AppNotifications()
        notifications.configureUpdateAction { openCount += 1 }
        notifications.handleResponse(
            categoryIdentifier: AppNotifications.updateCategoryIdentifier,
            actionIdentifier: UNNotificationDismissActionIdentifier)
        notifications.handleResponse(
            categoryIdentifier: "",
            actionIdentifier: UNNotificationDefaultActionIdentifier)
        #expect(openCount == 0)
    }

    @Test
    func `only update notices gain a silent foreground banner`() {
        #expect(AppNotifications.presentationOptions(
            categoryIdentifier: AppNotifications.updateCategoryIdentifier) == [.banner, .list])
        #expect(AppNotifications.presentationOptions(categoryIdentifier: "").isEmpty)
    }
}
