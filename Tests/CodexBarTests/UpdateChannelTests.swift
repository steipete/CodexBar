import Testing
@testable import CodexBar

@Suite
struct UpdateChannelTests {
    @Test
    func defaultChannelFromStableVersion() {
        #expect(UpdateChannel.defaultChannel(for: "1.2.3") == .stable)
    }

    @Test
    func defaultChannelFromPrereleaseVersion() {
        #expect(UpdateChannel.defaultChannel(for: "1.2.3-beta.1") == .beta)
        #expect(UpdateChannel.defaultChannel(for: "1.2.3-rc.1") == .beta)
        #expect(UpdateChannel.defaultChannel(for: "1.2.3-alpha") == .beta)
    }

    @Test
    func allowedSparkleChannels() {
        #expect(UpdateChannel.stable.allowedSparkleChannels == [""])
        #expect(UpdateChannel.beta.allowedSparkleChannels == ["", UpdateChannel.sparkleBetaChannel])
    }
}
