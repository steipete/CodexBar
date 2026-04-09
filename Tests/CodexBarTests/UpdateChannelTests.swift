import Testing
@testable import CodexBar

@Suite
struct UpdateChannelTests {
    @Test
    func usesSingleSparkleChannel() {
        #expect(UpdateChannel.allowedSparkleChannels == [""])
    }
}
