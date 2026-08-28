import Foundation

extension CodexUsageResponse.SpendControlLimitSnapshot {
    func codexCreditLimitSnapshot(updatedAt: Date) -> CodexCreditLimitSnapshot? {
        guard let limit, limit > 0 else { return nil }
        let used: Double = if let used {
            used
        } else if let remainingPercent {
            limit * max(0, min(100, 100 - remainingPercent)) / 100
        } else {
            0
        }
        let remainingPercent = self.remainingPercent ?? max(0, min(100, 100 - (used / limit * 100)))
        let resetsAt = self.resetsAt.flatMap { value -> Date? in
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return CodexCreditLimitSnapshot(
            used: used,
            limit: limit,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            updatedAt: updatedAt)
    }
}
