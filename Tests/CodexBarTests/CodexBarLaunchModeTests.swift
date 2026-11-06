import Foundation
import Testing
@testable import CodexBar

struct CodexBarLaunchModeTests {
    @Test @MainActor
    func `app allocator policy does not remain in the inherited environment`() {
        let key = "MallocLargeCache"
        let original = getenv(key).map { String(cString: $0) }
        defer {
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }
        setenv(key, "0", 1)
        // Materialize Foundation's view too, as subprocess launchers use it.
        let before = ProcessInfo.processInfo.environment[key]
        #expect(before == "0")

        CodexBarEntryPoint.removeAllocatorEnvironmentOverride()

        let inherited = ProcessInfo.processInfo.environment[key]
        #expect(inherited == nil)
        #expect(getenv(key) == nil)
    }

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
