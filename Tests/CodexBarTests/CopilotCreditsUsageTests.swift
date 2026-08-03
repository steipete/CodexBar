import Foundation
import Testing
@testable import CodexBarCore

struct CopilotCreditsUsageTests {
    @Test
    func `used percent divides credits by entitlement`() {
        let lane = CopilotCreditsUsage.Lane(creditsUsed: 31, entitlement: 3000, resetsAt: nil)
        let percent = try? #require(lane.usedPercent)
        #expect(abs((percent ?? 0) - 1.0333333) < 0.0001)
    }

    @Test
    func `used percent is nil without an entitlement`() {
        let lane = CopilotCreditsUsage.Lane(creditsUsed: 31, entitlement: nil, resetsAt: nil)
        #expect(lane.usedPercent == nil)
    }

    @Test
    func `used percent is nil for zero or negative entitlement`() {
        #expect(CopilotCreditsUsage.Lane(creditsUsed: 31, entitlement: 0, resetsAt: nil).usedPercent == nil)
        #expect(CopilotCreditsUsage.Lane(creditsUsed: 31, entitlement: -5, resetsAt: nil).usedPercent == nil)
    }

    @Test
    func `used percent is not clamped above one hundred`() {
        let lane = CopilotCreditsUsage.Lane(creditsUsed: 150, entitlement: 100, resetsAt: nil)
        #expect(lane.usedPercent == 150)
    }

    @Test
    func `round trips through codable`() throws {
        let usage = CopilotCreditsUsage(
            seat: CopilotCreditsUsage.Lane(creditsUsed: 31, entitlement: 3000, resetsAt: nil),
            org: nil,
            orgLogin: "example-org")
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(CopilotCreditsUsage.self, from: data)
        #expect(decoded == usage)
    }

    @Test
    func `usage snapshot carries copilot credits through codable`() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            copilotCredits: CopilotCreditsUsage(
                seat: CopilotCreditsUsage.Lane(creditsUsed: 31, entitlement: 3000, resetsAt: nil),
                org: nil,
                orgLogin: nil),
            updatedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.copilotCredits?.seat?.creditsUsed == 31)
        #expect(decoded.copilotCredits?.seat?.entitlement == 3000)
    }
}
