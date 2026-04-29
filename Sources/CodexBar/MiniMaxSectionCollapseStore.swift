import Foundation
import Observation

/// 进程内保存 MiniMax 菜单卡各分组折叠状态；`sectionTitle` 为 key，未覆盖时使用「行数 ≥ 5 默认折叠」。
@MainActor
@Observable
final class MiniMaxSectionCollapseStore {
    static let shared = MiniMaxSectionCollapseStore()

    private var overrides: [String: Bool] = [:]

    private init() {}

    /// - Parameters:
    ///   - sectionTitle: 分组标题（与 `MiniMaxSection.title` 一致）。
    ///   - rowCount: 该分组内行数；≥ `MiniMaxUILayoutMetrics.collapseThreshold` 时默认折叠。
    func isCollapsed(sectionTitle: String, rowCount: Int) -> Bool {
        if let stored = self.overrides[sectionTitle] {
            return stored
        }
        return rowCount >= MiniMaxUILayoutMetrics.collapseThreshold
    }

    func toggle(sectionTitle: String, rowCount: Int) {
        let current = self.isCollapsed(sectionTitle: sectionTitle, rowCount: rowCount)
        self.overrides[sectionTitle] = !current
    }

    /// 单测重置覆盖，避免用例互相污染。
    func resetOverridesForTesting() {
        self.overrides.removeAll()
    }
}
