import Testing
@testable import CodexBar

struct CodexBarLaunchModeTests {
    @Test
    func `normal launch starts the application`() {
        #expect(CodexBarLaunchMode.resolve(arguments: ["/Applications/CodexBar"]) == .application)
    }

    @Test
    func `hook event launch skips application initialization`() {
        #expect(CodexBarLaunchMode.resolve(
            arguments: ["/Applications/CodexBar", "--hook-event"]) == .hookEvent)
    }

    @Test
    func `hook event is recognized among other arguments`() {
        #expect(CodexBarLaunchMode.resolve(
            arguments: ["/Applications/CodexBar", "--verbose", "--hook-event"]) == .hookEvent)
    }

    @Test
    func `similar argument still starts the application`() {
        #expect(CodexBarLaunchMode.resolve(
            arguments: ["/Applications/CodexBar", "--hook-events"]) == .application)
    }
}
