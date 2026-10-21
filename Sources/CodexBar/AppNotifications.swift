import CodexBarCore
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()
    nonisolated static let updateCategoryIdentifier = "codexbar-update-available"

    private let centerProvider: @Sendable () -> UNUserNotificationCenter
    private let logger = CodexBarLog.logger(LogCategories.notifications)
    private var authorizationTask: Task<Bool, Never>?
    private var openUpdateSettings: (@MainActor () -> Void)?

    init(centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.centerProvider = centerProvider
        super.init()
    }

    func configureUpdateAction(_ openSettings: @escaping @MainActor () -> Void) {
        self.openUpdateSettings = openSettings
        guard !Self.isRunningUnderTests else { return }
        self.centerProvider().delegate = self
    }

    func handleResponse(categoryIdentifier: String, actionIdentifier: String) {
        guard categoryIdentifier == Self.updateCategoryIdentifier,
              actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        self.openUpdateSettings?()
    }

    nonisolated static func presentationOptions(categoryIdentifier: String) -> UNNotificationPresentationOptions {
        categoryIdentifier == self.updateCategoryIdentifier ? [.banner, .list] : []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    {
        Self.presentationOptions(categoryIdentifier: notification.request.content.categoryIdentifier)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async
    {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        await self.handleResponse(categoryIdentifier: category, actionIdentifier: action)
    }

    func requestAuthorizationOnStartup() {
        guard !Self.isRunningUnderTests else { return }
        _ = self.ensureAuthorizationTask()
    }

    func post(
        idPrefix: String,
        title: String,
        body: String,
        badge: NSNumber? = nil,
        soundEnabled: Bool = true,
        identifier: String? = nil,
        categoryIdentifier: String = "",
        isCurrent: @escaping @MainActor () -> Bool = { true },
        onCompletion: (@MainActor (Bool) -> Void)? = nil)
    {
        guard !Self.isRunningUnderTests else { return }
        let center = self.centerProvider()
        let logger = self.logger

        Task { @MainActor in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = soundEnabled ? .default : nil
            content.badge = badge
            content.categoryIdentifier = categoryIdentifier

            let request = UNNotificationRequest(
                identifier: identifier ?? "codexbar-\(idPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil)

            logger.info("posting", metadata: ["prefix": idPrefix])
            do {
                let delivered = try await Self.deliverIfCurrent(
                    authorize: { await self.ensureAuthorized() },
                    submit: { try await center.add(request) },
                    remove: {
                        center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    },
                    isCurrent: isCurrent)
                onCompletion?(delivered)
            } catch {
                onCompletion?(false)
                let errorText = String(describing: error)
                logger.error("failed to post", metadata: ["prefix": idPrefix, "error": errorText])
            }
        }
    }

    func remove(identifier: String) {
        guard !Self.isRunningUnderTests else { return }
        let center = self.centerProvider()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    @discardableResult
    static func deliverIfCurrent(
        authorize: () async -> Bool,
        submit: () async throws -> Void,
        remove: () -> Void,
        isCurrent: () -> Bool) async throws -> Bool
    {
        guard isCurrent(), await authorize(), isCurrent() else { return false }
        do {
            try await submit()
        } catch {
            remove()
            throw error
        }
        guard isCurrent() else {
            remove()
            return false
        }
        return true
    }

    // MARK: - Private

    private func ensureAuthorizationTask() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let task = Task { @MainActor in
            await self.requestAuthorization()
        }
        self.authorizationTask = task
        return task
    }

    private func ensureAuthorized() async -> Bool {
        let granted = await self.ensureAuthorizationTask().value
        // A later System Settings permission change must be observable after a denied attempt.
        if !granted { self.authorizationTask = nil }
        return granted
    }

    private func requestAuthorization() async -> Bool {
        if let existing = await self.notificationAuthorizationStatus() {
            if existing == .authorized || existing == .provisional {
                return true
            }
            if existing == .denied {
                return false
            }
        }

        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus? {
        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private static var isRunningUnderTests: Bool {
        // Swift Testing doesn't always set XCTest env vars, and removing XCTest imports from
        // the test target can make NSClassFromString("XCTestCase") return nil. If we're not
        // running inside an app bundle, treat it as "tests/headless" to avoid crashes when
        // accessing UNUserNotificationCenter.
        if Bundle.main.bundleURL.pathExtension != "app" { return true }
        return TestProcessSafety.isRunning
    }
}
