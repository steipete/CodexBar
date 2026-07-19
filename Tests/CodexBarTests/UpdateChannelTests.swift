import Testing
@testable import CodexBar

struct UpdateChannelTests {
    @Test
    func `default channel from stable version`() {
        #expect(UpdateChannel.defaultChannel(for: "1.2.3") == .stable)
    }

    @Test
    func `default channel from prerelease version`() {
        #expect(UpdateChannel.defaultChannel(for: "1.2.3-beta.1") == .beta)
        #expect(UpdateChannel.defaultChannel(for: "1.2.3-rc.1") == .beta)
        #expect(UpdateChannel.defaultChannel(for: "1.2.3-alpha") == .beta)
    }

    @Test
    func `allowed sparkle channels`() {
        #expect(UpdateChannel.stable.allowedSparkleChannels == [""])
        #expect(UpdateChannel.beta.allowedSparkleChannels == ["", UpdateChannel.sparkleBetaChannel])
    }
}
