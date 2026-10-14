import Foundation

/// Separates a short, actionable status from the subprocess output kept for diagnosis.
struct HomebrewUpdateFailure: LocalizedError, Equatable {
    enum Stage {
        case checking
        case preparing
        case installing
    }

    let stage: Stage
    let details: String

    var errorDescription: String? {
        self.details
    }

    var summary: String {
        switch self.stage {
        case .checking: L("Couldn’t check for updates")
        case .preparing: L("Couldn’t prepare the update")
        case .installing: L("Couldn’t update CodexBar")
        }
    }

    var repairCommand: String? {
        // Only suggest the known retired tap, never turn arbitrary process output into a command.
        guard self.stage == .preparing,
              self.details.contains("homebrew/homebrew-cask-versions does not exist!")
              || self.details.contains("homebrew/cask-versions does not exist!")
        else { return nil }
        return "brew untap homebrew/cask-versions"
    }
}

enum HomebrewUpgradeAvailability {
    private struct Response: Decodable {
        struct Cask: Decodable {
            let token: String
            let tap: String
            let version: String
            let disabled: Bool
        }

        let casks: [Cask]
    }

    static func verify(json: String, cask: HomebrewCask, targetVersion: String) throws {
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        guard response.casks.count == 1,
              let candidate = response.casks.first,
              candidate.token == "codexbar",
              candidate.tap == cask.rawValue,
              !candidate.disabled,
              candidate.version.wholeMatch(of: /[0-9]+(?:\.[0-9]+)*(?:[-.][A-Za-z0-9]+)*/) != nil
        else { throw HomebrewUpdateError.invalidCaskResponse }
        guard !HomebrewCaskVersion.isNewer(targetVersion, than: candidate.version) else {
            throw HomebrewUpdateError.versionUnavailable(available: candidate.version, requested: targetVersion)
        }
    }
}
