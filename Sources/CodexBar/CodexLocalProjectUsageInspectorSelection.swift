import Foundation
import Observation

/// Persistent Workspaces-window destination selection. The synthetic
/// All Workspaces destination and concrete project destinations survive window
/// reopen without coupling the raw usage snapshot to presentation state.
@MainActor
@Observable
final class CodexLocalProjectUsageInspectorSelection {
    private let defaults: UserDefaults
    private let projectKey = "codexLocalProjectUsageWindowSelectedProjectId"

    var selectedProjectID: String? {
        didSet {
            if let selectedProjectID, !selectedProjectID.isEmpty {
                self.defaults.set(selectedProjectID, forKey: self.projectKey)
            } else {
                self.defaults.removeObject(forKey: self.projectKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedProjectID = defaults.string(forKey: self.projectKey)
    }
}
