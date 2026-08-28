import Foundation

extension AntigravityStatusProbe {
    static func preferredLocalSnapshot(
        _ snapshots: [AntigravityStatusSnapshot],
        matchingAccountEmail expectedAccountEmail: String?) -> AntigravityStatusSnapshot?
    {
        var candidates = snapshots
        if let expected = self.normalizedAccountEmail(expectedAccountEmail) {
            let matches = snapshots.filter {
                guard let found = self.normalizedAccountEmail($0.accountEmail) else { return false }
                return found.caseInsensitiveCompare(expected) == .orderedSame
            }
            if !matches.isEmpty {
                candidates = matches
            }
        }

        var bestSnapshot: AntigravityStatusSnapshot?
        var bestScore = Int.min
        for snapshot in candidates {
            let score = self.localSnapshotScore(snapshot)
            if score > bestScore {
                bestSnapshot = snapshot
                bestScore = score
            }
        }
        return bestSnapshot
    }

    private static func normalizedAccountEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
