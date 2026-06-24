import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexBarTests {
    @Test
    func `icon renderer produces template image`() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 75,
            creditsRemaining: 500,
            stale: false,
            style: .codex)
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
    }

    @Test
    func `icon renderer renders at pixel aligned size`() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 75,
            creditsRemaining: 500,
            stale: false,
            style: .claude)
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(bitmapReps.contains { rep in
            rep.pixelsWide == 36 && rep.pixelsHigh == 36
        })
    }

    @Test
    func `icon renderer caches static icons`() {
        let first = IconRenderer.makeIcon(
            primaryRemaining: 42,
            weeklyRemaining: 17,
            creditsRemaining: 250,
            stale: false,
            style: .codex)
        let second = IconRenderer.makeIcon(
            primaryRemaining: 42,
            weeklyRemaining: 17,
            creditsRemaining: 250,
            stale: false,
            style: .codex)
        #expect(first === second)
    }

    @Test
    func `antigravity icon ignores legacy model quota lanes`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-compact-fallback-model",
                    title: "New Model",
                    window: RateWindow(
                        usedPercent: 64,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .antigravity)

        #expect(remaining.primary == nil)
        #expect(remaining.secondary == nil)
    }

    @Test
    func `antigravity quota summary icon shows session on top and weekly on bottom`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 84, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(usedPercent: 84, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Session",
                    window: RateWindow(usedPercent: 97, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude + GPT Session",
                    window: RateWindow(usedPercent: 98, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)

        #expect(windows.primary?.windowMinutes == 300)
        #expect(windows.primary?.remainingPercent == 2)
        #expect(windows.secondary?.windowMinutes == 10080)
        #expect(windows.secondary?.remainingPercent == 1)
    }

    @Test
    func `antigravity renderer draws primary above secondary`() throws {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 100,
            weeklyRemaining: 10,
            creditsRemaining: nil,
            stale: false,
            style: .antigravity)
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let matchingRep = bitmapReps.first { rep in
            rep.pixelsWide == 36 && rep.pixelsHigh == 36
        }
        let rep = try #require(matchingRep)

        func averageAlpha(xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> CGFloat {
            var total: CGFloat = 0
            var count: CGFloat = 0
            for y in yRange {
                for x in xRange {
                    total += (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
                    count += 1
                }
            }
            return total / count
        }

        let visualTopRightAlpha = averageAlpha(xRange: 24...30, yRange: 7...10)
        let visualBottomRightAlpha = averageAlpha(xRange: 24...30, yRange: 22...28)

        #expect(visualTopRightAlpha > visualBottomRightAlpha + 0.2)
    }

    @Test
    func `antigravity quota summary icon uses most constrained quota summary lanes`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Renamed Weekly",
                    window: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Renamed Session",
                    window: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Gemini Session",
                    window: RateWindow(usedPercent: 98, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)

        #expect(windows.primary?.remainingPercent == 2)
        #expect(windows.secondary?.remainingPercent == 1)
    }

    @Test
    func `antigravity quota summary icon can pair gemini session with claude gpt weekly`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Session",
                    window: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)

        #expect(windows.primary?.remainingPercent == 60)
        #expect(windows.secondary?.remainingPercent == 1)
    }

    @Test
    func `antigravity quota summary icon ignores unknown rows while ranking known lanes`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                    usageKnown: false),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)

        #expect(windows.primary == nil)
        #expect(windows.secondary?.remainingPercent == 1)
    }

    @Test
    func `antigravity used icon percent matches constrained claude gpt lane`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Session",
                    window: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude + GPT Session",
                    window: RateWindow(usedPercent: 95, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let percents = IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: .antigravity,
            showUsed: true)

        #expect(percents.primary == 95)
        #expect(percents.secondary == 40)
    }

    @Test
    func `antigravity quota summary icon falls back when gemini rows are absent`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude + GPT Session",
                    window: RateWindow(usedPercent: 75, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(usedPercent: 88, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)

        #expect(windows.primary?.remainingPercent == 25)
        #expect(windows.secondary?.remainingPercent == 12)
    }

    @Test
    func `antigravity quota summary icon tie break is stable`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-z-5h",
                    title: "Gemini Session",
                    window: RateWindow(
                        usedPercent: 50,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: "second-by-id")),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-a-5h",
                    title: "Gemini Session",
                    window: RateWindow(
                        usedPercent: 50,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: "first-by-id")),
            ],
            updatedAt: Date())

        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)

        #expect(windows.primary?.resetDescription == "first-by-id")
        #expect(windows.secondary == nil)
    }

    @Test
    func `perplexity icon falls back to purchased lane when bonus is exhausted`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .perplexity)
        #expect(remaining.primary == 80)
        #expect(remaining.secondary == 0)
    }

    @Test
    func `perplexity icon skips exhausted recurring lane when purchased credits remain`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .perplexity)
        #expect(remaining.primary == 80)
        #expect(remaining.secondary == 0)
    }

    @Test
    func `perplexity icon prefers purchased lane before bonus`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 45, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .perplexity)
        #expect(remaining.primary == 55)
        #expect(remaining.secondary == 80)
    }

    @Test
    func `kimi icon renders primary bar when secondary is nil`() throws {
        // Regression: Kimi account connected with usage, but no progress bar shown (issue #1043).
        // When secondary (rate limit) is absent, the icon renderer must still show
        // the primary (weekly quota) bar.
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 18.3, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .kimi)

        guard let primaryRemaining = remaining.primary else {
            Issue.record("remaining.primary was nil after IconRemainingResolver check")
            return
        }
        #expect(primaryRemaining > 0) // 81.7% remaining
        #expect(remaining.secondary == nil)

        let image = IconRenderer.makeIcon(
            primaryRemaining: remaining.primary,
            weeklyRemaining: remaining.secondary,
            creditsRemaining: nil,
            stale: false,
            style: .kimi)
        #expect(image.size.width > 0)
        #expect(image.isTemplate)

        // Prove the primary bar is actually rendered using pixel inspection.
        // Top bar rect: x ∈ [3, 33], y ∈ [19, 31] in the 36×36 canvas (barXPx=3, barWidthPx=30, y=19, h=12).
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep = try #require(bitmapReps.first { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })

        func alphaAt(px x: Int, _ y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        func regionHasFill(xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Bool {
            for y in yRange {
                for x in xRange where alphaAt(px: x, y) > 0.05 {
                    return true
                }
            }
            return false
        }

        // Primary bar (top track) must have fill to prove the progress bar rendered.
        #expect(regionHasFill(xRange: 3...33, yRange: 19...31))
    }

    @Test
    func `copilot icon can use selected budget as secondary lane`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "copilot-budget-agent",
                    title: "Budget - Copilot Agent Premium Requests",
                    window: RateWindow(usedPercent: 65, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(
            snapshot: snapshot,
            style: .copilot,
            secondaryOverrideWindowID: "copilot-budget-agent")

        #expect(remaining.primary == 80)
        #expect(remaining.secondary == 35)
    }

    @Test
    func `copying extra rate windows preserves subscription dates`() {
        let expiresAt = Date(timeIntervalSince1970: 1_810_656_000)
        let renewsAt = Date(timeIntervalSince1970: 1_810_569_600)
        let ampUsage = AmpUsageDetails(
            individualCredits: 12.5,
            workspaceBalances: [AmpWorkspaceBalance(name: "Team", remaining: 7.25)])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            ampUsage: ampUsage,
            subscriptionExpiresAt: expiresAt,
            subscriptionRenewsAt: renewsAt,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let copied = snapshot.with(extraRateWindows: [])

        #expect(copied.subscriptionExpiresAt == expiresAt)
        #expect(copied.subscriptionRenewsAt == renewsAt)
        #expect(copied.ampUsage == ampUsage)
    }

    @Test
    func `copying rate windows preserves provider payloads`() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let mimoUsage = MiMoUsageSnapshot(
            balance: 12.5,
            currency: "USD",
            tokenUsed: 25,
            tokenLimit: 100,
            tokenPercent: 0.25,
            updatedAt: updatedAt)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "test@example.com",
            accountOrganization: "Example",
            loginMethod: "OAuth")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: RateWindow(usedPercent: 30, windowMinutes: 60, resetsAt: nil, resetDescription: nil),
            mimoUsage: mimoUsage,
            cursorRequests: CursorRequestUsage(used: 10, limit: 50),
            subscriptionExpiresAt: updatedAt.addingTimeInterval(100),
            subscriptionRenewsAt: updatedAt.addingTimeInterval(200),
            updatedAt: updatedAt,
            identity: identity)

        let copied = snapshot.with(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))

        #expect(copied.primary?.usedPercent == 40)
        #expect(copied.secondary?.usedPercent == 50)
        #expect(copied.tertiary?.usedPercent == 30)
        #expect(copied.mimoUsage?.balance == 12.5)
        #expect(copied.cursorRequests?.used == 10)
        #expect(copied.subscriptionExpiresAt == updatedAt.addingTimeInterval(100))
        #expect(copied.subscriptionRenewsAt == updatedAt.addingTimeInterval(200))
        #expect(copied.identity?.accountOrganization == "Example")
    }

    @Test
    func `copying identity preserves provider payloads`() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let ampUsage = AmpUsageDetails(
            individualCredits: 12.5,
            workspaceBalances: [AmpWorkspaceBalance(name: "Team", remaining: 7.25)])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            ampUsage: ampUsage,
            cursorRequests: CursorRequestUsage(used: 10, limit: 50),
            subscriptionExpiresAt: updatedAt.addingTimeInterval(100),
            subscriptionRenewsAt: updatedAt.addingTimeInterval(200),
            updatedAt: updatedAt)
        let identity = ProviderIdentitySnapshot(
            providerID: .kilo,
            accountEmail: "test@example.com",
            accountOrganization: "Example",
            loginMethod: "API")

        let copied = snapshot.withIdentity(identity)

        #expect(copied.ampUsage == ampUsage)
        #expect(copied.cursorRequests?.used == 10)
        #expect(copied.subscriptionExpiresAt == updatedAt.addingTimeInterval(100))
        #expect(copied.subscriptionRenewsAt == updatedAt.addingTimeInterval(200))
        #expect(copied.identity?.accountOrganization == "Example")
    }

    @Test
    func `copilot icon falls back to chat lane when selected budget is unavailable`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            extraRateWindows: nil,
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(
            snapshot: snapshot,
            style: .copilot,
            secondaryOverrideWindowID: "copilot-budget-agent")

        #expect(remaining.primary == 80)
        #expect(remaining.secondary == 70)
    }

    @Test
    func `copilot icon uses selected budget in show used mode`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "copilot-budget-agent",
                    title: "Budget - Copilot Agent Premium Requests",
                    window: RateWindow(usedPercent: 65, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let percents = IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: .copilot,
            showUsed: true,
            secondaryOverrideWindowID: "copilot-budget-agent")

        #expect(percents.primary == 20)
        #expect(percents.secondary == 65)
    }

    @Test
    func `warp icon preserves exhausted bonus layout in show used mode`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let percents = IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: .warp,
            showUsed: true)

        #expect(percents.primary == 10)
        #expect(percents.secondary == 0)
    }

    @Test
    func `warp icon keeps unused bonus lane visible in show used mode`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let percents = IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: .warp,
            showUsed: true)

        #expect(percents.primary == 10)
        #expect(percents.secondary != nil)
        #expect(percents.secondary ?? 1 < 0.01)
    }

    @Test
    func `merged icon keeps exhausted warp bonus fully used`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let percents = IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: .warp,
            showUsed: true,
            renderingStyle: .combined)

        #expect(percents.primary == 10)
        #expect(percents.secondary == 100)
    }

    @Test
    @MainActor
    func `status icon accessibility uses percentage scale`() {
        #expect(
            StatusIconView.accessibilityPercentRemaining(50) ==
                String(format: L("%d percent remaining"), 50))
    }

    @Test
    func `codex icon promotes weekly only window into primary display lane`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .codex)
        #expect(remaining.primary == 75)
        #expect(remaining.secondary == nil)
    }

    @Test
    func `codex icon uses semantic projection lanes when durations drift`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 11040, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .codex)
        #expect(remaining.primary == 75)
        #expect(remaining.secondary == nil)
    }

    @Test
    func `status overlays cut halos through the quota bar and keep glyphs visible`() throws {
        let plain = IconRenderer.makeIcon(
            primaryRemaining: 100,
            weeklyRemaining: 100,
            creditsRemaining: nil,
            stale: false,
            style: .combined,
            statusIndicator: .none)
        let plainRep = try #require(plain.representations.compactMap { $0 as? NSBitmapImageRep }.first {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })

        func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        for indicator in [ProviderStatusIndicator.minor, .major] {
            let marked = IconRenderer.makeIcon(
                primaryRemaining: 100,
                weeklyRemaining: 100,
                creditsRemaining: nil,
                stale: false,
                style: .combined,
                statusIndicator: indicator)
            let markedRep = try #require(marked.representations.compactMap { $0 as? NSBitmapImageRep }.first {
                $0.pixelsWide == 36 && $0.pixelsHigh == 36
            })

            var cutoutPixels = 0
            var glyphPixels = 0
            for y in 0..<markedRep.pixelsHigh {
                for x in 0..<markedRep.pixelsWide {
                    let plainAlpha = alpha(plainRep, x: x, y: y)
                    let markedAlpha = alpha(markedRep, x: x, y: y)
                    if plainAlpha > 0.5, markedAlpha < 0.05 {
                        cutoutPixels += 1
                    }
                    if plainAlpha < 0.05, markedAlpha > 0.5 {
                        glyphPixels += 1
                    }
                }
            }

            #expect(cutoutPixels >= 8, "Expected halo cutout pixels for \(indicator)")
            #expect(glyphPixels >= 4, "Expected visible glyph pixels for \(indicator)")
        }
    }

    @Test
    func `icon renderer codex eyes punch through when unknown`() {
        // Regression: when remaining is nil, CoreGraphics inherits the previous fill alpha which caused
        // destinationOut “eyes” to become semi-transparent instead of fully punched through.
        let image = IconRenderer.makeIcon(
            primaryRemaining: nil,
            weeklyRemaining: 1,
            creditsRemaining: nil,
            stale: false,
            style: .codex)

        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep = bitmapReps.first(where: { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })
        #expect(rep != nil)
        guard let rep else { return }

        func alphaAt(px x: Int, _ y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let isTransparent: (Int, Int) -> Bool = { x, y in
            alphaAt(px: x, y) < 0.05
        }

        // Flood-fill from the border through transparent pixels to label the "outside".
        var visited = Array(repeating: Array(repeating: false, count: w), count: h)
        var queue: [(Int, Int)] = []
        queue.reserveCapacity(w * 2 + h * 2)

        func enqueueIfOutside(_ x: Int, _ y: Int) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            guard !visited[y][x], isTransparent(x, y) else { return }
            visited[y][x] = true
            queue.append((x, y))
        }

        for x in 0..<w {
            enqueueIfOutside(x, 0)
            enqueueIfOutside(x, h - 1)
        }
        for y in 0..<h {
            enqueueIfOutside(0, y)
            enqueueIfOutside(w - 1, y)
        }

        while let (x, y) = queue.first {
            queue.removeFirst()
            enqueueIfOutside(x + 1, y)
            enqueueIfOutside(x - 1, y)
            enqueueIfOutside(x, y + 1)
            enqueueIfOutside(x, y - 1)
        }

        // Any remaining transparent pixels not reachable from the border are internal holes (i.e. the eyes).
        var internalHoles = 0
        for y in 0..<h {
            for x in 0..<w where isTransparent(x, y) && !visited[y][x] {
                internalHoles += 1
            }
        }

        #expect(internalHoles >= 16) // at least one 4×4 eye block, but typically two eyes => 32
    }

    @Test
    func `icon renderer warp eyes cut out at expected centers`() {
        // Regression: Warp eyes should be tilted in-place and remain centered on the face.
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 50,
            creditsRemaining: nil,
            stale: false,
            style: .warp)

        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep = bitmapReps.first(where: { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })
        #expect(rep != nil)
        guard let rep else { return }

        func alphaAt(px x: Int, _ y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        func minAlphaNear(px cx: Int, _ cy: Int, radius: Int) -> CGFloat {
            var minAlpha: CGFloat = 1.0
            let x0 = max(0, cx - radius)
            let x1 = min(rep.pixelsWide - 1, cx + radius)
            let y0 = max(0, cy - radius)
            let y1 = min(rep.pixelsHigh - 1, cy + radius)
            for y in y0...y1 {
                for x in x0...x1 {
                    minAlpha = min(minAlpha, alphaAt(px: x, y))
                }
            }
            return minAlpha
        }

        func minAlphaNearEitherOrigin(px cx: Int, _ cy: Int, radius: Int) -> CGFloat {
            let flippedY = (rep.pixelsHigh - 1) - cy
            return min(minAlphaNear(px: cx, cy, radius: radius), minAlphaNear(px: cx, flippedY, radius: radius))
        }

        // These are the center pixels for the two Warp eye cutouts in the top bar (36×36 canvas).
        // If the eyes are rotated around the wrong origin, these points will not be fully punched out.
        let leftEyeCenter = (x: 11, y: 25)
        let rightEyeCenter = (x: 25, y: 25)

        // The eye ellipse height is even (8 px), so the exact center can land between pixel rows.
        // Assert via a small neighborhood search rather than a single pixel.
        #expect(minAlphaNearEitherOrigin(px: leftEyeCenter.x, leftEyeCenter.y, radius: 2) < 0.05)
        #expect(minAlphaNearEitherOrigin(px: rightEyeCenter.x, rightEyeCenter.y, radius: 2) < 0.05)

        // Sanity: nearby top bar track area should remain visible (not everything is transparent).
        let midAlpha = max(alphaAt(px: 18, 25), alphaAt(px: 18, (rep.pixelsHigh - 1) - 25))
        #expect(midAlpha > 0.05)
    }

    @Test
    func `account info parses snake case auth token`() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let token = Self.fakeJWT(email: "user@example.com", plan: "pro")
        let auth = ["tokens": ["id_token": token, "access_token": "access", "refresh_token": "refresh"]]
        let data = try JSONSerialization.data(withJSONObject: auth)
        let authURL = tmp.appendingPathComponent("auth.json")
        try data.write(to: authURL)

        let fetcher = UsageFetcher(environment: ["CODEX_HOME": tmp.path])
        let account = fetcher.loadAccountInfo()
        #expect(account.email == "user@example.com")
        #expect(account.plan == "pro")
    }

    @Test
    func `account info parses legacy camel case auth token`() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let token = Self.fakeJWT(email: "user@example.com", plan: "pro")
        let auth = ["tokens": ["idToken": token, "accessToken": "access", "refreshToken": "refresh"]]
        let data = try JSONSerialization.data(withJSONObject: auth)
        let authURL = tmp.appendingPathComponent("auth.json")
        try data.write(to: authURL)

        let fetcher = UsageFetcher(environment: ["CODEX_HOME": tmp.path])
        let account = fetcher.loadAccountInfo()
        #expect(account.email == "user@example.com")
        #expect(account.plan == "pro")
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()
        func b64(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        return "\(b64(header)).\(b64(payload))."
    }
}
