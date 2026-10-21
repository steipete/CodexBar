import Foundation

@MainActor
final class HomebrewUpdateNotifier {
    struct Dependencies {
        var lastSubmittedVersion: @MainActor () -> String?
        var saveSubmittedVersion: @MainActor (String) -> Void
        var post: @MainActor (
            String,
            @escaping @MainActor () -> Bool,
            @escaping @MainActor (Bool) -> Void) -> Void
        var remove: @MainActor (String) -> Void
    }

    private struct Attempt {
        let id: UUID
        var isCurrent = true
    }

    private let dependencies: Dependencies
    private var availableVersion: String?
    private var shouldNotify = false
    private var attempt: Attempt?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func update(availableVersion: String?, notify: Bool) {
        if let submitted = self.dependencies.lastSubmittedVersion(), submitted != availableVersion {
            self.dependencies.remove(submitted)
        }
        if self.availableVersion != availableVersion {
            if let previousVersion = self.availableVersion {
                self.dependencies.remove(previousVersion)
            }
            self.availableVersion = availableVersion
            self.shouldNotify = notify
            self.attempt?.isCurrent = false
        } else if notify {
            self.shouldNotify = true
        }
        if notify {
            self.postIfNeeded()
        }
    }

    private func postIfNeeded() {
        guard self.attempt == nil, self.shouldNotify, let version = self.availableVersion else { return }
        if let submitted = self.dependencies.lastSubmittedVersion(),
           !HomebrewCaskVersion.isNewer(version, than: submitted)
        {
            return
        }
        let id = UUID()
        self.attempt = Attempt(id: id)
        self.dependencies.post(
            version,
            { [weak self] in
                guard let self else { return false }
                return self.attempt?.id == id && self.attempt?.isCurrent == true
                    && self.availableVersion == version && self.shouldNotify
            },
            { [weak self] submitted in
                guard let self, let attempt = self.attempt, attempt.id == id else { return }
                self.attempt = nil
                if submitted, attempt.isCurrent, self.availableVersion == version {
                    self.dependencies.saveSubmittedVersion(version)
                }
                // Drain an invalidated delivery before starting another: an old request's cleanup
                // must not remove a newer notification for the same version.
                if !attempt.isCurrent {
                    self.postIfNeeded()
                }
            })
    }
}

extension HomebrewUpdateNotifier.Dependencies {
    @MainActor
    static var live: Self {
        let defaults = UserDefaults.standard
        let key = "homebrewUpdateLastSubmittedVersion"
        return Self(
            lastSubmittedVersion: { defaults.string(forKey: key) },
            saveSubmittedVersion: { defaults.set($0, forKey: key) },
            post: { version, isCurrent, completion in
                AppNotifications.shared.post(
                    idPrefix: "homebrew-update",
                    title: String(format: L("CodexBar %@ is available"), version),
                    body: L("update_available_notification_body"),
                    soundEnabled: false,
                    identifier: Self.identifier(version: version),
                    categoryIdentifier: AppNotifications.updateCategoryIdentifier,
                    isCurrent: isCurrent,
                    onCompletion: completion)
            },
            remove: { AppNotifications.shared.remove(identifier: Self.identifier(version: $0)) })
    }

    private static func identifier(version: String) -> String {
        "codexbar-homebrew-update-\(version)"
    }
}
