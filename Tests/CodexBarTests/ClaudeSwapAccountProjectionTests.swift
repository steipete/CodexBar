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
        #expect(active.snapshot?.identity?.accountOrganization == nil)
        #expect(active.snapshot?.identity?.accountID == "claude-swap:2")
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
            (.reloginRequired, "Re-login required"),
            (.apiKey, "API-key account"),
            (.keychainUnavailable, "Keychain"),
            (.noCredentials, "No stored credentials"),
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
            #expect(snapshot.canActivate == (entry.0 == .apiKey))
        }
    }

    @Test
    func `unavailable without windows or prior snapshot reports deferred polling`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: nil,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: false,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let snapshot = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(snapshot.snapshot == nil)
        #expect(snapshot.error == "Polling deferred until a limit resets.")
        #expect(snapshot.canActivate == true)
        #expect(snapshot.error?.contains("Usage fetch failed") != true)
    }

    @Test
    func `projects usage windows even when status is unavailable`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_003_600)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 42, resetsAt: nil)),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        let snapshot = try #require(account.snapshot)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary == nil)
        #expect(account.error == "Session limit reached. Resets in 1h.")
        #expect(account.error?.contains("Usage fetch failed") != true)
    }

    @Test
    func `unavailable attached windows drop expired lanes and keep remaining at limit`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: ClaudeSwapUsageWindow(
                        usedPercent: 100,
                        resetsAt: self.now.addingTimeInterval(-60)),
                    sevenDay: ClaudeSwapUsageWindow(
                        usedPercent: 100,
                        resetsAt: self.now.addingTimeInterval(86400))),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(account.snapshot?.primary == nil)
        #expect(account.snapshot?.secondary?.usedPercent == 100)
        let error = try #require(account.error)
        #expect(error.contains("Weekly limit reached"))
        #expect(!error.contains("Session limit reached"))
        #expect(!error.contains("Resets now"))
    }

    @Test
    func `names each exhausted window including scoped models`() throws {
        let sessionReset = Date(timeIntervalSince1970: 1_782_003_600)
        let weeklyReset = Date(timeIntervalSince1970: 1_782_259_200)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: sessionReset),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: weeklyReset),
                    scoped: [
                        ClaudeSwapScopedUsageWindow(name: "Fable", usedPercent: 100, resetsAt: weeklyReset),
                    ]),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(account.snapshot?.primary?.usedPercent == 100)
        #expect(account.snapshot?.secondary?.usedPercent == 100)
        #expect(account.snapshot?.extraRateWindows?.first?.window.usedPercent == 100)
        #expect(account.error == [
            "Session limit reached. Resets in 1h.",
            "Weekly limit reached. Resets in 3d.",
            "Fable limit reached. Resets in 3d.",
        ].joined(separator: " "))
    }

    @Test
    func `unavailable without windows retains previous snapshot as current at limit usage`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_259_200)
        let previousList = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset)),
            ])
        let previous = ClaudeSwapAccountProjection.accountSnapshots(from: previousList, now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now.addingTimeInterval(3600)).first)
        #expect(account.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "1"))
        #expect(account.snapshot?.primary?.usedPercent == 100)
        #expect(account.snapshot?.secondary?.usedPercent == 100)
        #expect(account.snapshot?.updatedAt == self.now)
        let error = try #require(account.error)
        #expect(error.contains("Session limit reached"))
        #expect(error.contains("Weekly limit reached"))
        #expect(!error.contains("Usage fetch failed"))
        #expect(!error.contains("last successful update"))
    }

    @Test
    func `unavailable retain drops expired windows and keeps remaining at limit lanes`() throws {
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "a@b.c",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(
                            usedPercent: 100,
                            resetsAt: self.now.addingTimeInterval(-60)),
                        sevenDay: ClaudeSwapUsageWindow(
                            usedPercent: 100,
                            resetsAt: self.now.addingTimeInterval(86400))),
                ]),
            now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.snapshot?.primary == nil)
        #expect(account.snapshot?.secondary?.usedPercent == 100)
        let error = try #require(account.error)
        #expect(error.contains("Weekly limit reached"))
        #expect(!error.contains("Session limit reached"))
        #expect(!error.contains("Resets now"))
    }

    @Test
    func `unavailable retain drops a snapshot whose at limit windows have all reset`() throws {
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "a@b.c",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(
                            usedPercent: 100,
                            resetsAt: self.now.addingTimeInterval(-3600)),
                        sevenDay: ClaudeSwapUsageWindow(
                            usedPercent: 100,
                            resetsAt: self.now.addingTimeInterval(-60))),
                ]),
            now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.snapshot == nil)
        #expect(account.error == "Polling deferred until a limit resets.")
    }

    @Test
    func `unavailable retain drops exhausted windows without a reset timestamp`() throws {
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "a@b.c",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: nil),
                        sevenDay: ClaudeSwapUsageWindow(
                            usedPercent: 100,
                            resetsAt: self.now.addingTimeInterval(86400))),
                ]),
            now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.snapshot?.primary == nil)
        #expect(account.snapshot?.secondary?.usedPercent == 100)
        let error = try #require(account.error)
        #expect(error.contains("Weekly limit reached"))
        #expect(!error.contains("Session limit reached"))
    }

    @Test
    func `unavailable retain drops unknown reset lanes that are not exhausted`() throws {
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "a@b.c",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 40, resetsAt: nil),
                        sevenDay: ClaudeSwapUsageWindow(
                            usedPercent: 100,
                            resetsAt: self.now.addingTimeInterval(86400))),
                ]),
            now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.snapshot?.primary == nil)
        #expect(account.snapshot?.secondary?.usedPercent == 100)
        let error = try #require(account.error)
        #expect(error.contains("Weekly limit reached"))
        #expect(!error.contains("Session limit reached"))
    }

    @Test
    func `token expired does not retain a previous usage snapshot`() throws {
        let previousList = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: nil),
                    sevenDay: nil),
            ])
        let previous = ClaudeSwapAccountProjection.accountSnapshots(from: previousList, now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .tokenExpired,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.snapshot == nil)
        #expect(account.error?.contains("Token expired") == true)
    }

    @Test
    func `token expired with cached windows stays metrics less`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .tokenExpired,
                    fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: nil),
                    sevenDay: ClaudeSwapUsageWindow(usedPercent: 80, resetsAt: nil)),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(account.snapshot == nil)
        #expect(account.error?.contains("Token expired") == true)
    }

    @Test
    func `unavailable does not reuse a previous snapshot from a different email`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_259_200)
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "old@example.com",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset),
                        sevenDay: nil),
                ]),
            now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "new@example.com",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.displayLabel == "new@example.com")
        #expect(account.snapshot == nil)
        #expect(account.error == "Polling deferred until a limit resets.")
    }

    @Test
    func `unavailable does not retain a previous snapshot that is not at a limit`() throws {
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "a@b.c",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 20, resetsAt: nil),
                        sevenDay: nil),
                ]),
            now: self.now)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.snapshot == nil)
        #expect(account.error == "Polling deferred until a limit resets.")
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
    func `projects model scoped weekly windows through claude usage rows`() throws {
        let reset = Date(timeIntervalSince1970: 1_784_620_800)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: nil,
                    sevenDay: nil,
                    scoped: [
                        ClaudeSwapScopedUsageWindow(name: "Fable", usedPercent: 33, resetsAt: reset),
                        ClaudeSwapScopedUsageWindow(name: "All models", usedPercent: 42, resetsAt: reset),
                    ]),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        let snapshot = try #require(account.snapshot)
        #expect(account.error == nil)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        let scoped = try #require(snapshot.extraRateWindows)
        #expect(scoped.count == 1)
        #expect(scoped.first?.id == "claude-weekly-scoped-fable")
        #expect(scoped.first?.title == "Fable only")
        #expect(scoped.first?.window.usedPercent == 33)
        #expect(scoped.first?.window.windowMinutes == 10080)
        #expect(scoped.first?.window.resetsAt == reset)
    }

    @Test
    func `filtered generic scope does not hide missing usage error`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "a@b.c",
                    isActive: true,
                    usageStatus: .ok,
                    fiveHour: nil,
                    sevenDay: nil,
                    scoped: [
                        ClaudeSwapScopedUsageWindow(name: "All models", usedPercent: 42, resetsAt: nil),
                    ]),
            ])

        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        #expect(account.snapshot == nil)
        #expect(account.error == "No usage windows reported.")
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

    @Test
    func `unavailable retain ignores cached windows after the slot account changes`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_259_200)
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "old@example.com",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset),
                        sevenDay: nil),
                ]),
            now: self.now)
        let cached = ClaudeSwapRetainedUsageStore.snapshotsForRetention(previous)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "new@example.com",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: cached,
                now: self.now).first)
        #expect(account.displayLabel == "new@example.com")
        #expect(account.snapshot == nil)
        #expect(account.error == "Polling deferred until a limit resets.")
    }

    @Test
    func `unavailable retain ignores cached windows when the slot has no email`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_259_200)
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset),
                        sevenDay: nil),
                ]),
            now: self.now)
        let cached = ClaudeSwapRetainedUsageStore.snapshotsForRetention(previous)
        #expect(cached.isEmpty)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: previous,
                now: self.now).first)
        #expect(account.displayLabel == "Account 1")
        #expect(account.snapshot == nil)
        #expect(account.error == "Polling deferred until a limit resets.")
    }

    @Test
    func `unavailable retain keeps cached windows for the same slot account`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_259_200)
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "same@example.com",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset),
                        sevenDay: nil),
                ]),
            now: self.now)
        let cached = ClaudeSwapRetainedUsageStore.snapshotsForRetention(previous)
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "same@example.com",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: cached,
                now: self.now).first)
        #expect(account.snapshot?.primary?.usedPercent == 100)
        #expect(account.snapshot?.identity?.accountEmail == "same@example.com")
        #expect(account.error?.contains("Session limit reached") == true)
    }

    @Test
    func `unavailable retain ignores a cache entry with no account discriminator`() throws {
        let reset = Date(timeIntervalSince1970: 1_782_259_200)
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "old@example.com",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: reset),
                        sevenDay: nil),
                ]),
            now: self.now)
        let stripped = previous.map { account in
            ProviderAccountUsageSnapshot(
                id: account.id,
                provider: account.provider,
                displayLabel: "",
                isActive: account.isActive,
                snapshot: account.snapshot.map { snapshot in
                    UsageSnapshot(
                        primary: snapshot.primary,
                        secondary: snapshot.secondary,
                        extraRateWindows: snapshot.extraRateWindows,
                        updatedAt: snapshot.updatedAt,
                        identity: nil)
                },
                error: nil,
                sourceLabel: account.sourceLabel)
        }
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "old@example.com",
                    isActive: true,
                    usageStatus: .unavailable,
                    fiveHour: nil,
                    sevenDay: nil),
            ])

        let account = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(
                from: list,
                previousAccounts: stripped,
                now: self.now).first)
        #expect(account.snapshot == nil)
        #expect(account.error == "Polling deferred until a limit resets.")
    }

    @Test
    func `previous accounts prefer in-memory snapshots over an empty cache load`() {
        let previous = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    ClaudeSwapAccountRow(
                        number: 1,
                        email: "work@example.com",
                        isActive: true,
                        usageStatus: .ok,
                        fiveHour: ClaudeSwapUsageWindow(usedPercent: 40, resetsAt: nil),
                        sevenDay: nil),
                ]),
            now: self.now)
        #expect(ClaudeSwapRetainedUsageStore.previousAccounts(inMemory: previous).count == previous.count)
        #expect(ClaudeSwapRetainedUsageStore.previousAccounts(inMemory: []).isEmpty)
    }
}
