#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct ElevenLabsUsageSnapshotLinuxTests {
    private func snapshot(
        characterCount: Int,
        characterLimit: Int,
        voiceSlotsUsed: Int? = nil,
        voiceLimit: Int? = nil) -> ElevenLabsUsageSnapshot
    {
        ElevenLabsUsageSnapshot(
            tier: "creator",
            characterCount: characterCount,
            characterLimit: characterLimit,
            voiceSlotsUsed: voiceSlotsUsed,
            professionalVoiceSlotsUsed: nil,
            voiceLimit: voiceLimit,
            professionalVoiceLimit: nil,
            currentOverage: nil,
            status: "active",
            resetsAt: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test
    func `in-range character usage maps to its percent`() {
        let usage = self.snapshot(characterCount: 25000, characterLimit: 100_000).toUsageSnapshot()
        #expect(abs((usage.primary?.usedPercent ?? 0) - 25) < 0.01)
    }

    @Test
    func `character overage clamps used percent to 100`() {
        // ElevenLabs models overage explicitly (currentOverage), so characterCount > characterLimit
        // is a real state. The percent must cap at 100 like sibling credit providers instead of
        // flowing 150 into RateWindow.usedPercent (which does not clamp).
        let usage = self.snapshot(characterCount: 150_000, characterLimit: 100_000).toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
    }

    @Test
    func `voice slot overage clamps used percent to 100`() {
        let usage = self.snapshot(
            characterCount: 0,
            characterLimit: 100_000,
            voiceSlotsUsed: 12,
            voiceLimit: 10).toUsageSnapshot()
        let voice = usage.extraRateWindows?.first { $0.id == "voice-slots" }
        #expect(voice?.window.usedPercent == 100)
    }
}
#endif
