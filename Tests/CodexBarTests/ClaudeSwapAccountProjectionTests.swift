import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapAccountProjectionTests {
    @Test
    func `adapter failures mark retained account snapshots as stale`() {
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: nil,
            adapterError: "timed out") == "Showing the last successful update: timed out")
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: "Token expired.",
            adapterError: "timed out") == "Token expired.")
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: nil,
            adapterError: "timed out",
            switchError: "store locked") == "Account switch failed: store locked")
        #expect(ClaudeSwapAccountProjection.displayError(
            accountError: "API-key account",
            adapterError: nil,
            switchError: "store locked") == "Account switch failed: store locked")
    }

    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `projects rows into provider neutral snapshots with active account first`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_170_999)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 2,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "work@example.com",
                    isActive: false,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 25, resetsAt: reset),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 16.5, resetsAt: nil)),
                ClaudeSwapAccountRow(
                    number: 2,
                    email: "personal@example.com",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 80, resetsAt: nil),
                    sevenDay: nil),
            ])

        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now)
        #expect(snapshots.count == 2)

        let active = try #require(snapshots.first)
        #expect(active.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "2"))
        #expect(active.provider == .claude)
        #expect(active.displayLabel == "personal@example.com")
        #expect(active.isActive == true)
        #expect(active.canActivate == false)
        #expect(active.error == nil)
        #expect(active.sourceLabel == "claude-swap")
        #expect(active.snapshot?.primary?.usedPercent == 80)
        #expect(active.snapshot?.primary?.windowMinutes == 300)
        #expect(active.snapshot?.secondary == nil)
        #expect(active.snapshot?.updatedAt == self.now)
        #expect(active.snapshot?.identity?.accountEmail == "personal@example.com")
        #expect(active.snapshot?.identity?.loginMethod == "claude-swap")

        let inactive = try #require(snapshots.last)
        #expect(inactive.id.opaqueID == "1")
        #expect(inactive.isActive == false)
        #expect(inactive.canActivate == true)
        #expect(inactive.snapshot?.primary?.resetsAt == reset)
        #expect(inactive.snapshot?.secondary?.usedPercent == 16.5)
        #expect(inactive.snapshot?.secondary?.windowMinutes == 10080)
    }

    @Test
    func `maps sentinel statuses to per account errors without usage`() throws {
        let rows: [(ClaudeSwapUsageStatus, String)] = [
            (.tokenExpired, "Token expired"),
            (.apiKey, "API-key account"),
            (.keychainUnavailable, "Keychain"),
            (.noCredentials, "No stored credentials"),
            (.unavailable, "Usage fetch failed"),
            (.unknown("mystery"), "mystery"),
        ]

        for (index, entry) in rows.enumerated() {
            let list = ClaudeSwapAccountList(
                activeAccountNumber: nil,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: index + 1,
                        email: "a@b.c",
                        isActive: false,
                        usageStatus: entry.0,
                        fiveHour: nil,
                        sevenDay: nil),
                ])
            let snapshot = try #require(
                ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
            #expect(snapshot.snapshot == nil)
            let error = try #require(snapshot.error)
            #expect(error.contains(entry.1))
            let expectedCanActivate = entry.0 == .apiKey || entry.0 == .unavailable
            #expect(snapshot.canActivate == expectedCanActivate)
        }
    }

    @Test
    func `ok row without windows reports missing usage instead of an empty card`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let snapshot = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(snapshot.snapshot == nil)
        #expect(snapshot.error == "No usage windows reported.")
    }

    @Test
    func `falls back to ordinal label when email is empty`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: nil,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 3,
                    email: "",
                    isActive: false,
                    usageStatus: .noCredentials,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let snapshot = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(snapshot.displayLabel == "Account 3")
    }
}
