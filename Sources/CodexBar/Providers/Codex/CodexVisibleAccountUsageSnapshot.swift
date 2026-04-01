import CodexBarCore
import Foundation

struct CodexVisibleAccountUsageSnapshot: Sendable {
    let visibleAccountID: String
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?
}
