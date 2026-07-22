import Testing
@testable import CodexBar

struct SpendDashboardPresentationTests {
    @Test
    func `empty dashboard reports refresh until validation finishes`() {
        #expect(SpendDashboardEmptyState.make(isRefreshing: true).title == L("Refreshing"))
        #expect(SpendDashboardEmptyState.make(isRefreshing: false).title == L("No local cost history yet"))
    }
}
