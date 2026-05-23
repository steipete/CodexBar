import AppKit
import CodexBarCore
import Combine
import Foundation

/// Detects the active frontmost application and maps its bundle identifier to a UsageProvider.
///
/// This is used to show the merged menu bar icon for the provider associated with
/// the currently focused application when "Show active provider" is enabled.
///
/// - Note: Bundle identifier mappings are conservative. Only well-established, unambiguous
///   mappings are included based on verified bundle IDs from installed apps or confirmed
///   in existing codebase references.
@preconcurrency @MainActor
final class ActiveApplicationProviderDetector: ObservableObject {
    // MARK: - Bundle Identifier Mappings

    /// Known bundle identifiers mapped to their corresponding UsageProvider.
    ///
    /// Ambiguous mappings (e.g., VS Code could mean Copilot, Codex, OpenAI, etc.)
    /// are not included by default to avoid incorrect provider selection.
    private nonisolated static let bundleIdentifierToProvider: [String: UsageProvider] = [
        // JetBrains IDEs - maps to jetbrains provider
        // Confirmed from existing jetbrainsIDEBasePath setting and ProviderImplementationRegistry
        "com.jetbrains.intellij": .jetbrains,
        "com.jetbrains.CLion": .jetbrains,
        "com.jetbrains.AppCode": .jetbrains,
        "com.jetbrains.GoLand": .jetbrains,
        "com.jetbrains.DataGrip": .jetbrains,
        "com.jetbrains.Rider": .jetbrains,
        "com.jetbrains.PyCharm": .jetbrains,
        "com.jetbrains.WebStorm": .jetbrains,
        "com.jetbrains.PhpStorm": .jetbrains,
        "com.jetbrains.RubyMine": .jetbrains,
        "com.jetbrains.idea": .jetbrains,

        // Cursor - bundle ID "com.cursorcursor.cursor" is documented in the CursorProviderImplementation
        "com.cursorcursor.cursor": .cursor,

        // VS Code - NOT mapped: VS Code is used with many providers (Copilot, Codex, OpenAI, etc.)
        // making the mapping ambiguous. Users can manually select their provider.

        // Xcode - NOT mapped: Xcode is not a provider-specific IDE. While some users may use
        // Claude via Xcode extension, the mapping would be too ambiguous to be reliable.
    ]

    // MARK: - Published State

    /// The provider matching the currently active application, if any.
    @Published private(set) var currentProvider: UsageProvider?

    // MARK: - Private State

    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private let observeApplicationChanges: Bool

    // MARK: - Initialization

    /// - Parameter observeApplicationChanges: If false, skips registering for workspace notifications.
    ///   Useful for testing without triggering actual app activation events.
    init(observeApplicationChanges: Bool = true) {
        self.observeApplicationChanges = observeApplicationChanges
        if observeApplicationChanges {
            self.observeFrontmostApplicationChanges()
        }
    }

    // MARK: - Public Methods

    /// Returns the provider that should be shown for the given bundle identifier.
    /// Returns nil if the bundle identifier is unknown or maps to a disabled provider.
    nonisolated func provider(for bundleIdentifier: String?) -> UsageProvider? {
        guard let bundleIdentifier, let provider = Self.bundleIdentifierToProvider[bundleIdentifier] else {
            return nil
        }
        return provider
    }

    /// Updates the current provider based on the active frontmost application.
    func updateFromFrontmostApplication() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        self.currentProvider = self.provider(for: frontmostApp?.bundleIdentifier)
    }

    // MARK: - Private Methods

    private func observeFrontmostApplicationChanges() {
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let self else { return }
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let bundleID {
                    self.currentProvider = Self.bundleIdentifierToProvider[bundleID]
                } else {
                    self.currentProvider = nil
                }
            }
        }
    }

    deinit {
        guard let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }

    private func handleApplicationActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleIdentifier = app.bundleIdentifier
        else {
            self.currentProvider = nil
            return
        }
        self.currentProvider = Self.bundleIdentifierToProvider[bundleIdentifier]
    }
}
