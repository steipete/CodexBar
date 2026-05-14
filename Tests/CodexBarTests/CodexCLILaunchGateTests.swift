import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexCLILaunchGateTests {
    @Test
    func `background launch failures suppress repeated background launches until cooldown expires`() {
        let gate = CodexCLILaunchGate.shared
        gate.resetForTesting()
        defer { gate.resetForTesting() }
        let now = Date(timeIntervalSince1970: 100)

        let message = gate.recordLaunchFailure(
            binary: "/opt/homebrew/bin/codex",
            message: "\"codex\" was not opened because it contains malware.",
            now: now)

        #expect(message?.contains("background refresh is paused") == true)
        #expect(gate.backgroundSkipMessage(
            binary: "/opt/homebrew/bin/codex",
            now: now.addingTimeInterval(60),
            interaction: .background) == message)
        #expect(gate.backgroundSkipMessage(
            binary: "/opt/homebrew/bin/codex",
            now: now.addingTimeInterval(60),
            interaction: .userInitiated) == nil)
        #expect(gate.backgroundSkipMessage(
            binary: "/opt/homebrew/bin/codex",
            now: now.addingTimeInterval(CodexCLILaunchGate.cooldown + 1),
            interaction: .background) == nil)
    }

    @Test
    func `PTY infrastructure failures do not suppress future Codex launches`() {
        #expect(CodexCLILaunchGate.shouldThrottleLaunchFailure("openpty failed") == false)
        #expect(CodexCLILaunchGate.shouldThrottleLaunchFailure("write to PTY failed") == false)
        #expect(CodexCLILaunchGate.shouldThrottleLaunchFailure("The operation could not be completed") == true)
    }
}
