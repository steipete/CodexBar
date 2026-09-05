import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct QuotaRowVisibilityTests {
    private static func snapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: RateWindow(
                        usedPercent: 12,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "claude-weekly-scoped-design",
                    title: "Design only",
                    window: RateWindow(
                        usedPercent: 55,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: now)
    }

    private static func model(
        hiddenQuotaRowIDs: Set<String>,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: Self.snapshot(now: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hiddenQuotaRowIDs: hiddenQuotaRowIDs,
            hidePersonalInfo: false,
            now: now))
    }

    @Test
    func `hidden quota rows are dropped from the menu metrics`() throws {
        let now = Date()

        let allVisible = try Self.model(hiddenQuotaRowIDs: [], now: now)
        #expect(allVisible.metrics.map(\.id).contains("claude-weekly-scoped-fable"))
        #expect(allVisible.metrics.map(\.id).contains("claude-weekly-scoped-design"))

        let hidden = try Self.model(hiddenQuotaRowIDs: ["claude-weekly-scoped-fable"], now: now)
        #expect(hidden.metrics.map(\.id).contains("claude-weekly-scoped-fable") == false)
        // Only the hidden row disappears; the other lanes keep rendering.
        #expect(hidden.metrics.map(\.id).contains("claude-weekly-scoped-design"))
        #expect(hidden.metrics.count == allVisible.metrics.count - 1)
    }

    @Test
    func `hiding a row is scoped to one provider`() {
        let hiddenForClaude = QuotaRowVisibilityState.updating(
            [:],
            provider: .claude,
            id: "claude-weekly-scoped-fable",
            visible: false)

        #expect(hiddenForClaude == [UsageProvider.claude.rawValue: ["claude-weekly-scoped-fable"]])
        #expect(QuotaRowVisibilityState.hiddenIDs(
            in: hiddenForClaude ?? [:],
            provider: .codex).isEmpty)
    }

    @Test
    func `hiding and restoring rows round-trips`() throws {
        var raw: [String: [String]] = [:]
        raw = try #require(QuotaRowVisibilityState.updating(
            raw, provider: .claude, id: "claude-weekly-scoped-fable", visible: false))
        raw = try #require(QuotaRowVisibilityState.updating(
            raw, provider: .claude, id: "claude-weekly-scoped-design", visible: false))
        #expect(QuotaRowVisibilityState.hiddenIDs(in: raw, provider: .claude).count == 2)

        raw = try #require(QuotaRowVisibilityState.updating(
            raw, provider: .claude, id: "claude-weekly-scoped-fable", visible: true))
        #expect(QuotaRowVisibilityState.hiddenIDs(in: raw, provider: .claude) == ["claude-weekly-scoped-design"])

        raw = try #require(QuotaRowVisibilityState.clearing(raw, provider: .claude))
        // The provider entry is removed rather than left as an empty list.
        #expect(raw[UsageProvider.claude.rawValue] == nil)
    }

    @Test
    func `redundant updates report no change`() {
        // Showing an already-visible row, or hiding an already-hidden one, must not rewrite storage.
        #expect(QuotaRowVisibilityState.updating(
            [:], provider: .claude, id: "claude-weekly-scoped-fable", visible: true) == nil)
        #expect(QuotaRowVisibilityState.clearing([:], provider: .claude) == nil)

        let hidden = [UsageProvider.claude.rawValue: ["claude-weekly-scoped-fable"]]
        #expect(QuotaRowVisibilityState.updating(
            hidden, provider: .claude, id: "claude-weekly-scoped-fable", visible: false) == nil)
    }

    @Test
    func `disabled Spark usage does not report spark rows as independently visible`() {
        let spark = Self.extraWindow(id: CodexAdditionalRateLimitMapper.sparkWindowID, title: "Codex Spark 5-hour")
        let sparkWeekly = Self.extraWindow(
            id: CodexAdditionalRateLimitMapper.sparkWeeklyWindowID,
            title: "Codex Spark Weekly")
        let other = Self.extraWindow(id: "codex-other-limit", title: "Other Codex limit")
        let gates = Self.gates(provider: .codex, codexSparkUsageVisible: false)

        #expect(gates.allows(spark) == false)
        #expect(gates.allows(sparkWeekly) == false)
        #expect(gates.allows(other))

        let listed = QuotaRowVisibilityListing.rows(
            reported: [spark, sparkWeekly, other],
            hiddenIDs: [spark.id, sparkWeekly.id],
            gates: gates)
        #expect(listed.map(\.id) == [other.id])
        #expect(QuotaRowVisibilityListing.hasIndependentlyHiddenRows(
            listed: listed,
            hiddenIDs: [spark.id, sparkWeekly.id]) == false)
    }

    @Test
    func `disabled optional credits hide all Codex extra rows including Show all`() {
        let spark = Self.extraWindow(id: CodexAdditionalRateLimitMapper.sparkWindowID)
        let other = Self.extraWindow(id: "codex-other-limit")
        let gates = Self.gates(provider: .codex, showOptionalCreditsAndExtraUsage: false)

        #expect(gates.allows(spark) == false)
        #expect(gates.allows(other) == false)

        let listed = QuotaRowVisibilityListing.rows(
            reported: [spark, other],
            hiddenIDs: [spark.id, other.id],
            gates: gates)
        #expect(listed.isEmpty)
        #expect(QuotaRowVisibilityListing.hasIndependentlyHiddenRows(
            listed: listed,
            hiddenIDs: [spark.id, other.id]) == false)
    }

    @Test
    func `disabled Daily Routines does not report that row as independently visible`() {
        let fable = Self.extraWindow(id: "claude-weekly-scoped-fable", title: "Fable only")
        let routines = Self.extraWindow(id: "claude-routines", title: "Daily Routines")
        let gates = Self.gates(provider: .claude, claudeDailyRoutinesUsageVisible: false)

        #expect(gates.allows(routines) == false)
        #expect(gates.allows(fable))

        let listed = QuotaRowVisibilityListing.rows(
            reported: [fable, routines],
            hiddenIDs: [routines.id],
            gates: gates)
        #expect(listed.map(\.id) == [fable.id])
        #expect(QuotaRowVisibilityListing.hasIndependentlyHiddenRows(
            listed: listed,
            hiddenIDs: [routines.id]) == false)
    }

    @Test
    func `disabled optional credits hide Claude Daily Routines but keep model-scoped extras`() {
        let fable = Self.extraWindow(id: "claude-weekly-scoped-fable", title: "Fable only")
        let routines = Self.extraWindow(id: "claude-routines", title: "Daily Routines")
        let gates = Self.gates(provider: .claude, showOptionalCreditsAndExtraUsage: false)

        #expect(gates.allows(routines) == false)
        #expect(gates.allows(fable))

        let listed = QuotaRowVisibilityListing.rows(
            reported: [fable, routines],
            hiddenIDs: [],
            gates: gates)
        #expect(listed.map(\.id) == [fable.id])
    }

    @Test
    func `disabled Copilot extras do not report budget rows as independently visible`() {
        let budget = Self.extraWindow(id: "copilot-budget-agent", title: "Budget - Copilot Agent Premium Requests")
        let gates = Self.gates(provider: .copilot, copilotBudgetExtrasEnabled: false)

        #expect(gates.allows(budget) == false)
        let listed = QuotaRowVisibilityListing.rows(
            reported: [budget],
            hiddenIDs: [budget.id],
            gates: gates)
        #expect(listed.isEmpty)
        #expect(QuotaRowVisibilityListing.hasIndependentlyHiddenRows(
            listed: listed,
            hiddenIDs: [budget.id]) == false)
    }

    @Test
    func `Show all cannot resurrect family-gated extra rows`() {
        let spark = Self.extraWindow(id: CodexAdditionalRateLimitMapper.sparkWindowID)
        let other = Self.extraWindow(id: "codex-other-limit")
        let gates = Self.gates(provider: .codex, codexSparkUsageVisible: false)
        var hidden: Set<String> = [spark.id, other.id]

        let before = QuotaRowVisibilityListing.rows(reported: [spark, other], hiddenIDs: hidden, gates: gates)
        #expect(before.map(\.id) == [other.id])
        #expect(QuotaRowVisibilityListing.hasIndependentlyHiddenRows(listed: before, hiddenIDs: hidden))

        hidden.removeAll()
        let afterShowAll = QuotaRowVisibilityListing.rows(
            reported: [spark, other],
            hiddenIDs: hidden,
            gates: gates)
        #expect(afterShowAll.map(\.id) == [other.id])
        #expect(afterShowAll.map(\.id).contains(spark.id) == false)
    }

    @Test
    func `family-gated extra rows stay dropped from menu metrics`() throws {
        let now = Date()
        let sparkHidden = try Self.codexModel(
            extraWindows: [
                Self.extraWindow(id: CodexAdditionalRateLimitMapper.sparkWindowID, title: "Codex Spark 5-hour"),
                Self.extraWindow(id: "codex-other-limit", title: "Other Codex limit"),
            ],
            showOptionalCreditsAndExtraUsage: true,
            codexSparkUsageVisible: false,
            now: now)
        #expect(sparkHidden.metrics.map(\.id).contains(CodexAdditionalRateLimitMapper.sparkWindowID) == false)
        #expect(sparkHidden.metrics.map(\.id).contains("codex-other-limit"))

        let optionalCreditsOff = try Self.codexModel(
            extraWindows: [
                Self.extraWindow(id: CodexAdditionalRateLimitMapper.sparkWindowID),
                Self.extraWindow(id: "codex-other-limit"),
            ],
            showOptionalCreditsAndExtraUsage: false,
            codexSparkUsageVisible: true,
            now: now)
        #expect(optionalCreditsOff.metrics.map(\.id).contains(CodexAdditionalRateLimitMapper.sparkWindowID) == false)
        #expect(optionalCreditsOff.metrics.map(\.id).contains("codex-other-limit") == false)
    }

    private static func extraWindow(id: String, title: String? = nil) -> NamedRateWindow {
        NamedRateWindow(
            id: id,
            title: title ?? id,
            window: RateWindow(usedPercent: 10, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))
    }

    private static func gates(
        provider: UsageProvider,
        showOptionalCreditsAndExtraUsage: Bool = true,
        claudeDailyRoutinesUsageVisible: Bool = true,
        codexSparkUsageVisible: Bool = true,
        copilotBudgetExtrasEnabled: Bool = true) -> QuotaRowFamilyGates
    {
        QuotaRowFamilyGates(
            provider: provider,
            showOptionalCreditsAndExtraUsage: showOptionalCreditsAndExtraUsage,
            claudeDailyRoutinesUsageVisible: claudeDailyRoutinesUsageVisible,
            codexSparkUsageVisible: codexSparkUsageVisible,
            copilotBudgetExtrasEnabled: copilotBudgetExtrasEnabled)
    }

    private static func codexModel(
        extraWindows: [NamedRateWindow],
        showOptionalCreditsAndExtraUsage: Bool,
        codexSparkUsageVisible: Bool,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        return UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                extraRateWindows: extraWindows,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptionalCreditsAndExtraUsage,
            codexSparkUsageVisible: codexSparkUsageVisible,
            hidePersonalInfo: false,
            now: now))
    }
}

@MainActor
struct QuotaRowFamilyGateSettingsTests {
    @Test
    func `SettingsStore visibility getter honors family gates and Show all cannot resurrect them`() {
        let settings = testSettingsStore(suiteName: "QuotaRowFamilyGateSettingsTests-visibility")
        let sparkID = CodexAdditionalRateLimitMapper.sparkWindowID
        let otherID = "codex-other-limit"
        let routinesID = "claude-routines"
        let fableID = "claude-weekly-scoped-fable"
        let copilotID = "copilot-budget-agent"

        settings.setQuotaRow(sparkID, visible: false, for: .codex)
        settings.setQuotaRow(otherID, visible: false, for: .codex)
        settings.codexSparkUsageVisible = false
        #expect(settings.isQuotaRowVisible(sparkID, for: .codex) == false)
        #expect(settings.isQuotaRowVisible(otherID, for: .codex) == false)

        settings.showAllQuotaRows(for: .codex)
        #expect(settings.isQuotaRowVisible(sparkID, for: .codex) == false)
        #expect(settings.isQuotaRowVisible(otherID, for: .codex))

        settings.showOptionalCreditsAndExtraUsage = false
        #expect(settings.isQuotaRowVisible(otherID, for: .codex) == false)
        settings.showAllQuotaRows(for: .codex)
        #expect(settings.isQuotaRowVisible(sparkID, for: .codex) == false)
        #expect(settings.isQuotaRowVisible(otherID, for: .codex) == false)

        settings.showOptionalCreditsAndExtraUsage = true
        settings.claudeDailyRoutinesUsageVisible = false
        #expect(settings.isQuotaRowVisible(routinesID, for: .claude) == false)
        #expect(settings.isQuotaRowVisible(fableID, for: .claude))
        settings.showAllQuotaRows(for: .claude)
        #expect(settings.isQuotaRowVisible(routinesID, for: .claude) == false)

        settings.copilotBudgetExtrasEnabled = false
        #expect(settings.isQuotaRowVisible(copilotID, for: .copilot) == false)
        settings.showAllQuotaRows(for: .copilot)
        #expect(settings.isQuotaRowVisible(copilotID, for: .copilot) == false)
    }
}
