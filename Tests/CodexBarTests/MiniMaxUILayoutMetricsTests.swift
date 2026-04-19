import Testing
@testable import CodexBar

struct MiniMaxUILayoutMetricsTests {
    @Test
    func `preferred menu usage height uses content height when under cap`() {
        let height = MiniMaxUILayoutMetrics.preferredMenuUsageHeight(
            contentHeight: 180,
            visibleScreenHeight: 1000)
        #expect(height == 180)
    }

    @Test
    func `preferred menu usage height clamps to cap when content is taller`() {
        let cap = MiniMaxUILayoutMetrics.menuUsageScrollMaxHeight(visibleScreenHeight: 900)
        let height = MiniMaxUILayoutMetrics.preferredMenuUsageHeight(
            contentHeight: cap + 240,
            visibleScreenHeight: 900)
        #expect(height == cap)
    }

    @Test
    func `menu usage height falls back when screen height unavailable`() {
        #expect(
            MiniMaxUILayoutMetrics.menuUsageScrollMaxHeight(visibleScreenHeight: nil) ==
                MiniMaxUILayoutMetrics.menuScrollFallbackHeight)
    }
}
