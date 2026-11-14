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
        Task { _ = await self.ensureAuthorized() }
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
                        await withCheckedContinuation { continuation in
                            self.remove(identifier: request.identifier) { continuation.resume() }
                        }
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

    func remove(identifier: String, completion: @escaping @Sendable () -> Void = {}) {
        guard !Self.isRunningUnderTests else {
            completion()
            return
        }
        let centerProvider = self.centerProvider
        Self.scheduleRemoval(identifiers: [identifier]) { identifiers in
            let center = centerProvider()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            completion()
        }
    }

    /// `removePendingNotificationRequests` waits on a synchronous XPC reply from usernotificationsd.
    /// A stalled reply must not freeze a main-actor caller, so removals use a serial utility queue.
    /// The queue preserves removal order without blocking menu interaction.
    nonisolated static func scheduleRemoval(
        identifiers: [String],
        perform: @escaping @Sendable ([String]) -> Void)
    {
        self.removalQueue.async { perform(identifiers) }
    }

    private nonisolated static let removalQueue = DispatchQueue(
        label: "com.steipete.codexbar.notifications.removal",
        qos: .utility)

    @discardableResult
    static func deliverIfCurrent(
        authorize: () async -> Bool,
        submit: () async throws -> Void,
        remove: () async -> Void,
        isCurrent: () -> Bool) async throws -> Bool
    {
        guard isCurrent(), await authorize(), isCurrent() else { return false }
        do {
            try await submit()
        } catch {
            await remove()
            throw error
        }
        guard isCurrent() else {
            await remove()
            return false
        }
        return true
    }

    // MARK: - Private

    private func ensureAuthorized() async -> Bool {
        let task = self.authorizationTask ?? Task { @MainActor in await self.requestAuthorization() }
        self.authorizationTask = task
        let granted = await task.value
        // A later System Settings permission change must be observable after a denied attempt.
        if !granted { self.authorizationTask = nil }
        return granted
    }

    private func requestAuthorization() async -> Bool {
        let center = self.centerProvider()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return await (try? center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
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
