import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIUnificationGoldenTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `affected provider text output golden`() {
        let output = Self.textFixtures.map { fixture in
            CLIRenderer.renderText(
                provider: fixture.provider,
                snapshot: fixture.snapshot,
                credits: nil,
                context: RenderContext(
                    header: fixture.provider.rawValue,
                    status: nil,
                    useColor: false,
                    resetStyle: .countdown),
                now: Self.now)
        }.joined(separator: "\n---\n")

        let expected = """
        == factory ==
        5-hour: 90% left [==========--]
        Weekly: 80% left [=========---]
        Monthly: 70% left [========----]
        ---
        == grok ==
        Credits: 89% left [==========--]
        ---
        == crof ==
        Credits: 88% left [==========--]
        ---
        == sub2api ==
        Daily quota: 87% left [==========--]
        Weekly quota: 86% left [==========--]
        ---
        == amp ==
        Other usage: 85% left [==========--]
        Orb usage: 84% left [==========--]
        ---
        == kilo ==
        Credits: 83% left [=========---]
        Renews after top-up
        Plan: Kilo Pass
        Activity: Auto top-up: enabled
        ---
        == qoder ==
        Credits: 82% left [=========---]
        500 weighted tokens
        ---
        == clawrouter ==
        ---
        == devin ==
        Extra usage: $25.00
        ---
        == claude ==
        Extra usage balance: $40.00
        ---
        == xai ==
        ---
        == codex ==
        Session: 95% left [===========-]
        Pace: 15% in reserve | Expected 20% used | Lasts until reset
        Resets in 4h
        Weekly: 75% left [=========---]
        Pace: 4% in reserve | Expected 29% used | Lasts until reset
        Resets in 5d
        ---
        == claude ==
        Session: 60% left [=======-----]
        Pace: 20% in deficit | Expected 20% used | Projected empty in 1h 30m
        Resets in 4h
        Weekly: 50% left [======------]
        Pace: 21% in deficit | Expected 29% used | Runs out in 2d
        Resets in 5d
        ---
        == opencode ==
        Weekly: 70% left [========----]
        Pace: On pace | Expected 29% used | Runs out in 4d 16h
        Resets in 5d
        ---
        == ollama ==
        Session: 90% left [==========--]
        Resets in 4h
        Weekly: 80% left [=========---]
        Pace: 9% in reserve | Expected 29% used | Lasts until reset
        Resets in 5d
        ---
        == kimi ==
        7-day usage: 70% left [========----]
        Pace: 13% in reserve | Expected 43% used | Lasts until reset
        Resets in 4d
        5-hour usage: 90% left [==========--]
        Pace: 10% in reserve | Expected 20% used | Lasts until reset
        Resets in 4h
        ---
        == notion ==
        Rolling: 80% left [=========---]
        Pace: 3% in deficit | Expected 17% used | Projected empty in 4h
        Resets in 5h
        """
        #expect(output == expected)
    }

    @Test
    func `affected provider cards output golden`() {
        let output = Self.cardFixtures.map { fixture in
            let card = CLICardsRenderer.makeCard(CLICardBuildInput(
                provider: fixture.provider,
                snapshot: fixture.snapshot,
                credits: nil,
                source: "fixture",
                status: nil,
                notes: [],
                useColor: false,
                resetStyle: .countdown,
                weeklyWorkDays: nil,
                now: Self.now))
            return CLICardsRenderer.render(
                cards: [card],
                failures: [],
                terminalWidth: 42,
                useColor: false)
        }.joined(separator: "\n---\n")

        let expected = """
        ╭────────────────────────────────────────╮
        │ Droid [fixture]                        │
        │ ────────────────────────────────────── │
        │ 5-hour                        90% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     ] │
        │                                        │
        │ Weekly                        80% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━        ] │
        │                                        │
        │ Monthly                       70% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━            ] │
        ╰────────────────────────────────────────╯
        ---
        ╭────────────────────────────────────────╮
        │ Grok [fixture]                         │
        │ ────────────────────────────────────── │
        │ Credits                       89% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     ] │
        ╰────────────────────────────────────────╯
        ---
        ╭────────────────────────────────────────╮
        │ Crof [fixture]                         │
        │ ────────────────────────────────────── │
        │ Credits                       88% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━      ] │
        ╰────────────────────────────────────────╯
        ---
        ╭────────────────────────────────────────╮
        │ sub2api [fixture]                      │
        │ ────────────────────────────────────── │
        │ Daily quota                   87% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━      ] │
        │                                        │
        │ Weekly quota                  86% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━      ] │
        ╰────────────────────────────────────────╯
        ---
        ╭────────────────────────────────────────╮
        │ Amp [fixture]                          │
        │ ────────────────────────────────────── │
        │ Other usage                   85% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━       ] │
        │                                        │
        │ Orb usage                     84% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━       ] │
        ╰────────────────────────────────────────╯
        ---
        ╭────────────────────────────────────────╮
        │ Kilo [fixture]          PLAN Kilo Pass │
        │ ────────────────────────────────────── │
        │ Credits                       83% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━       ] │
        │ Renews after top-up                    │
        │ Activity:         Auto top-up: enabled │
        ╰────────────────────────────────────────╯
        ---
        ╭────────────────────────────────────────╮
        │ Qoder [fixture]                        │
        │ ────────────────────────────────────── │
        │ Credits                       82% left │
        │ [ ━━━━━━━━━━━━━━━━━━━━━━━━━━━        ] │
        │ 500 weighted tokens                    │
        ╰────────────────────────────────────────╯
        """
        #expect(output == expected)
    }

    // swiftlint:disable function_body_length
    @Test
    func `affected provider JSON output golden`() throws {
        let payloads = Self.paceFixtures.map { fixture in
            ProviderPayload(
                provider: fixture.provider,
                account: nil,
                version: nil,
                source: "fixture",
                status: nil,
                usage: fixture.snapshot,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: nil,
                pace: CLIRenderer.providerPacePayload(
                    provider: fixture.provider,
                    snapshot: fixture.snapshot,
                    now: Self.now))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payloads)
        let output = try #require(String(data: data, encoding: .utf8))

        let expected = """
        [
          {
            "pace" : {
              "primary" : {
                "deltaPercent" : -15,
                "expectedUsedPercent" : 20,
                "stage" : "farBehind",
                "summary" : "15% in reserve | Expected 20% used | Lasts until reset",
                "willLastToReset" : true
              },
              "secondary" : {
                "deltaPercent" : -4,
                "expectedUsedPercent" : 29,
                "stage" : "slightlyBehind",
                "summary" : "4% in reserve | Expected 29% used | Lasts until reset",
                "willLastToReset" : true
              }
            },
            "provider" : "codex",
            "source" : "fixture",
            "usage" : {
              "primary" : {
                "resetsAt" : 1700014400,
                "usedPercent" : 5,
                "windowMinutes" : 300
              },
              "secondary" : {
                "resetsAt" : 1700432000,
                "usedPercent" : 25,
                "windowMinutes" : 10080
              },
              "tertiary" : null,
              "updatedAt" : 1700000000
            }
          },
          {
            "pace" : {
              "primary" : {
                "deltaPercent" : 20,
                "etaSeconds" : 5400,
                "expectedUsedPercent" : 20,
                "stage" : "farAhead",
                "summary" : "20% in deficit | Expected 20% used | Projected empty in 1h 30m",
                "willLastToReset" : false
              },
              "secondary" : {
                "deltaPercent" : 21,
                "etaSeconds" : 172800,
                "expectedUsedPercent" : 29,
                "stage" : "farAhead",
                "summary" : "21% in deficit | Expected 29% used | Runs out in 2d",
                "willLastToReset" : false
              }
            },
            "provider" : "claude",
            "source" : "fixture",
            "usage" : {
              "primary" : {
                "resetsAt" : 1700014400,
                "usedPercent" : 40,
                "windowMinutes" : 300
              },
              "secondary" : {
                "resetsAt" : 1700432000,
                "usedPercent" : 50,
                "windowMinutes" : 10080
              },
              "tertiary" : null,
              "updatedAt" : 1700000000
            }
          },
          {
            "pace" : {
              "secondary" : {
                "deltaPercent" : 1,
                "etaSeconds" : 403200,
                "expectedUsedPercent" : 29,
                "stage" : "onTrack",
                "summary" : "On pace | Expected 29% used | Runs out in 4d 16h",
                "willLastToReset" : false
              }
            },
            "provider" : "opencode",
            "source" : "fixture",
            "usage" : {
              "primary" : null,
              "secondary" : {
                "resetsAt" : 1700432000,
                "usedPercent" : 30,
                "windowMinutes" : 10080
              },
              "tertiary" : null,
              "updatedAt" : 1700000000
            }
          },
          {
            "pace" : {
              "secondary" : {
                "deltaPercent" : -9,
                "expectedUsedPercent" : 29,
                "stage" : "behind",
                "summary" : "9% in reserve | Expected 29% used | Lasts until reset",
                "willLastToReset" : true
              }
            },
            "provider" : "ollama",
            "source" : "fixture",
            "usage" : {
              "primary" : {
                "resetsAt" : 1700014400,
                "usedPercent" : 10
              },
              "secondary" : {
                "resetsAt" : 1700432000,
                "usedPercent" : 20,
                "windowMinutes" : 10080
              },
              "tertiary" : null,
              "updatedAt" : 1700000000
            }
          },
          {
            "pace" : {
              "primary" : {
                "deltaPercent" : -13,
                "expectedUsedPercent" : 43,
                "stage" : "farBehind",
                "summary" : "13% in reserve | Expected 43% used | Lasts until reset",
                "willLastToReset" : true
              },
              "secondary" : {
                "deltaPercent" : -10,
                "expectedUsedPercent" : 20,
                "stage" : "behind",
                "summary" : "10% in reserve | Expected 20% used | Lasts until reset",
                "willLastToReset" : true
              }
            },
            "provider" : "kimi",
            "source" : "fixture",
            "usage" : {
              "primary" : {
                "resetsAt" : 1700345600,
                "usedPercent" : 30,
                "windowMinutes" : 10080
              },
              "secondary" : {
                "resetsAt" : 1700014400,
                "usedPercent" : 10,
                "windowMinutes" : 300
              },
              "tertiary" : null,
              "updatedAt" : 1700000000
            }
          },
          {
            "pace" : {
              "primary" : {
                "deltaPercent" : 3,
                "etaSeconds" : 14400,
                "expectedUsedPercent" : 17,
                "stage" : "slightlyAhead",
                "summary" : "3% in deficit | Expected 17% used | Projected empty in 4h",
                "willLastToReset" : false
              }
            },
            "provider" : "notion",
            "source" : "fixture",
            "usage" : {
              "primary" : {
                "resetsAt" : 1700018000,
                "usedPercent" : 20,
                "windowMinutes" : 360
              },
              "secondary" : null,
              "tertiary" : null,
              "updatedAt" : 1700000000
            }
          }
        ]
        """
        #expect(output == expected)
    }

    // swiftlint:enable function_body_length

    private struct Fixture {
        let provider: UsageProvider
        let snapshot: UsageSnapshot
    }

    private static var textFixtures: [Fixture] {
        [
            Fixture(provider: .factory, snapshot: snapshot(
                primary: window(used: 10, minutes: 300),
                secondary: window(used: 20, minutes: 10080),
                tertiary: window(used: 30, minutes: 43200))),
            Fixture(provider: .grok, snapshot: snapshot(
                primary: window(used: 11, minutes: 120))),
            Fixture(provider: .crof, snapshot: snapshot(
                primary: window(used: 12, minutes: nil))),
            Fixture(provider: .sub2api, snapshot: snapshot(
                primary: window(used: 13, minutes: 1440),
                secondary: window(used: 14, minutes: 10080))),
            Fixture(provider: .amp, snapshot: snapshot(
                primary: window(used: 15, minutes: 43200),
                secondary: window(used: 16, minutes: 43200))),
            Fixture(provider: .kilo, snapshot: snapshot(
                primary: RateWindow(
                    usedPercent: 17,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "Renews after top-up"),
                loginMethod: "Kilo Pass · Auto top-up: enabled")),
            Fixture(provider: .qoder, snapshot: snapshot(
                primary: RateWindow(
                    usedPercent: 18,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "500 weighted tokens"))),
            Fixture(provider: .clawrouter, snapshot: costSnapshot(
                used: 1,
                limit: 10,
                period: "Monthly")),
            Fixture(provider: .devin, snapshot: costSnapshot(
                used: 25,
                limit: 0,
                period: "Extra usage balance")),
            Fixture(provider: .claude, snapshot: costSnapshot(
                used: 0,
                limit: 0,
                period: "Extra usage",
                balance: 40)),
            Fixture(provider: .xai, snapshot: costSnapshot(
                used: 30,
                limit: 0,
                period: "Prepaid credits")),
        ] + paceFixtures
    }

    private static var cardFixtures: [Fixture] {
        Array(textFixtures.prefix(7))
    }

    private static var paceFixtures: [Fixture] {
        [
            Fixture(provider: .codex, snapshot: snapshot(
                primary: window(used: 5, minutes: 300, resetAfter: 4 * 60 * 60),
                secondary: window(used: 25, minutes: 10080, resetAfter: 5 * 24 * 60 * 60))),
            Fixture(provider: .claude, snapshot: snapshot(
                primary: window(used: 40, minutes: 300, resetAfter: 4 * 60 * 60),
                secondary: window(used: 50, minutes: 10080, resetAfter: 5 * 24 * 60 * 60))),
            Fixture(provider: .opencode, snapshot: snapshot(
                secondary: window(used: 30, minutes: 10080, resetAfter: 5 * 24 * 60 * 60))),
            Fixture(provider: .ollama, snapshot: snapshot(
                primary: window(used: 10, minutes: nil, resetAfter: 4 * 60 * 60),
                secondary: window(used: 20, minutes: 10080, resetAfter: 5 * 24 * 60 * 60))),
            Fixture(provider: .kimi, snapshot: snapshot(
                primary: window(
                    used: 30,
                    minutes: KimiProviderDescriptor.weeklyWindowMinutes,
                    resetAfter: 4 * 24 * 60 * 60),
                secondary: window(
                    used: 10,
                    minutes: KimiProviderDescriptor.sessionWindowMinutes,
                    resetAfter: 4 * 60 * 60))),
            Fixture(provider: .notion, snapshot: snapshot(
                primary: window(
                    used: 20,
                    minutes: NotionProviderDescriptor.rollingWindowMaxMinutes,
                    resetAfter: 5 * 60 * 60))),
        ]
    }

    private static func window(used: Double, minutes: Int?, resetAfter: TimeInterval? = nil) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: resetAfter.map { Self.now.addingTimeInterval($0) },
            resetDescription: nil)
    }

    private static func snapshot(
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        loginMethod: String? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: self.now,
            identity: loginMethod.map {
                ProviderIdentitySnapshot(
                    providerID: .kilo,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: $0)
            })
    }

    private static func costSnapshot(
        used: Double,
        limit: Double,
        period: String,
        balance: Double? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: used,
                limit: limit,
                currencyCode: "USD",
                period: period,
                balance: balance,
                updatedAt: self.now),
            updatedAt: self.now)
    }
}
