import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SessionUsagePresentationTests {
    @Test
    func `search finds a named conversation case insensitively without changing accounting`() {
        let session = Self.session(id: "thread-alpha", title: "Fix cache accounting")
        let original = session
        let matches = SessionUsagePresentation.sessions([session], matching: "  CACHE  ", hidePersonalInfo: false)
        #expect(matches == [original])
        #expect(session == original)
    }

    @Test
    func `search keeps IDs available but cannot reveal hidden conversation names`() {
        let session = Self.session(id: "thread-alpha", title: "Confidential customer incident")
        #expect(SessionUsagePresentation.sessions(
            [session],
            matching: "customer",
            hidePersonalInfo: true).isEmpty)
        #expect(SessionUsagePresentation.sessions(
            [session],
            matching: "ALPHA",
            hidePersonalInfo: true) == [session])
    }

    @Test
    func `search considers all retained conversations before ordering`() {
        let sessions = (0..<120).map { Self.session(id: "thread-\($0)", title: "Conversation \($0)") }
        #expect(SessionUsagePresentation.sessions(sessions, matching: "", hidePersonalInfo: false).count == 120)
        #expect(SessionUsagePresentation.sessions(
            sessions,
            matching: "Conversation 119",
            hidePersonalInfo: false).map(\.sessionID) == ["thread-119"])
    }

    @Test
    func `conversations are ordered by recency with a stable tie break`() {
        let oldest = Self.session(id: "old", activity: 1)
        let latestB = Self.session(id: "b", activity: 2)
        let latestA = Self.session(id: "a", activity: 2)
        #expect(SessionUsagePresentation.sessions(
            [oldest, latestB, latestA],
            matching: "",
            hidePersonalInfo: false).map(\.sessionID) == ["a", "b", "old"])
    }

    @Test
    func `uncached input excludes cache hits and does not add reasoning again`() {
        let session = Self.session(id: "example")
        #expect(SessionUsagePresentation.uncachedInput(session) == 30)
        #expect(session.inputTokens == 120)
        #expect(session.cachedInputTokens == 90)
        #expect(session.outputTokens == 20)
        #expect(session.reasoningTokens == 10)
        #expect(session.totalTokens == 140)
    }

    @Test
    func `unknown or inconsistent cached input stays unavailable instead of becoming zero`() {
        #expect(SessionUsagePresentation.uncachedInput(Self.session(id: "missing", cached: nil)) == nil)
        #expect(SessionUsagePresentation.uncachedInput(Self.session(id: "invalid", cached: 121)) == nil)
        #expect(SessionUsagePresentation.uncachedInput(Self.session(id: "all-cached", cached: 120)) == 0)
    }

    @Test
    func `cost conversion preserves unknown zero and source currency semantics`() {
        #expect(SessionUsagePresentation.convertedCost(nil, multiplier: 2) == nil)
        #expect(SessionUsagePresentation.convertedCost(0, multiplier: 2) == 0)
        #expect(SessionUsagePresentation.convertedCost(3, multiplier: 2) == 6)
        #expect(SessionUsagePresentation.convertedCost(.infinity, multiplier: 1) == nil)
        #expect(SessionUsagePresentation.convertedCost(3, multiplier: .infinity) == nil)
        #expect(SessionUsagePresentation.costText(0.0001, multiplier: 1, currencyCode: "USD") == "$0.0001")
        #expect(SessionUsagePresentation.costText(0, multiplier: 1, currencyCode: "USD") == "$0.00")
        #expect(SessionUsagePresentation.costText(0.0000001, multiplier: 1, currencyCode: "USD") == "<$0.000001")
    }

    @Test
    func `token and cost sorting supports both directions with unknown values last`() {
        let sessions = [
            Self.session(id: "unknown", total: nil, cost: nil),
            Self.session(id: "large", total: 1000, cost: 0),
            Self.session(id: "small", total: 10, cost: 2),
        ]
        for (order, ascending, expected) in [
            (SessionUsagePresentation.Sort.tokens, false, ["large", "small", "unknown"]),
            (.tokens, true, ["small", "large", "unknown"]),
            (.cost, false, ["small", "large", "unknown"]),
            (.cost, true, ["large", "small", "unknown"]),
        ] {
            #expect(SessionUsagePresentation.sessions(
                sessions,
                matching: "",
                hidePersonalInfo: false,
                sort: order,
                ascending: ascending)
                .map(\.sessionID) == expected)
        }
    }

    @Test
    func `sorting rejects invalid values and resolves ties by recent activity`() {
        let sessions = [
            Self.session(id: "invalid", total: -1, cost: .infinity),
            Self.session(id: "old", activity: 1),
            Self.session(id: "new", activity: 2),
        ]
        for order in [SessionUsagePresentation.Sort.tokens, .cost] {
            #expect(SessionUsagePresentation.sessions(
                sessions,
                matching: "",
                hidePersonalInfo: false,
                sort: order,
                ascending: true)
                .map(\.sessionID) == ["new", "old", "invalid"])
        }
    }

    @Test
    func `tool activity uses the same reporting days and excludes the following midnight`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15)))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 2,
            daily: [],
            updatedAt: now)
        let range = SessionUsagePresentation.toolActivityRange(snapshot: snapshot, calendar: calendar)
        #expect(calendar.component(.day, from: range.lowerBound) == 20)
        #expect(calendar.component(.hour, from: range.lowerBound) == 0)
        #expect(calendar.component(.day, from: range.upperBound) == 22)
        #expect(range.contains(now))
        #expect(!range.contains(range.upperBound))
    }

    @Test
    func `performance only session retains unfiltered native tool activity`() throws {
        let activity = Date(timeIntervalSince1970: 1)
        let sample = try #require(CostUsageTurnPerformanceSample(
            completedAt: activity,
            outputTokens: 10,
            durationMilliseconds: 1000))
        let session = CostUsageSessionBreakdown(
            sessionID: Self.toolSource.sessionID,
            lastActivity: activity,
            inputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            requestCount: nil,
            costUSD: nil,
            modelBreakdowns: [],
            turnPerformanceSamples: [sample],
            toolActivitySource: Self.toolSource)
        let browser = try Self.toolBrowser(session)
        let view = try #require(browser.toolActivityView(for: session))
        #expect(view.source == Self.toolSource)
        #expect(view.turnID == nil)
        #expect(view.range == browser.context.activityRange)
        #expect(view.timeZone.identifier == "Asia/Shanghai")
        #expect(view.hidePersonalInfo)
        #expect(view.lastActivity == activity)
        #expect(session.totalTokens == nil)
        #expect(session.costUSD == nil)
    }

    @Test
    func `unattributed usage keeps native operations accessible at session scope`() throws {
        let session = Self.session(
            id: Self.toolSource.sessionID,
            turns: [Self.toolTurn(nil)],
            toolActivitySource: Self.toolSource)
        let browser = try Self.toolBrowser(session)
        let view = try #require(browser.toolActivityView(for: session))
        #expect(view.source == Self.toolSource)
        #expect(view.turnID == nil)
        #expect(view.range == browser.context.activityRange)
    }

    @Test
    func `attributed sessions retain an all operations route alongside scoped tool lists`() throws {
        for turns in [[Self.toolTurn("native-turn")], [Self.toolTurn(nil), Self.toolTurn("native-turn")]] {
            let session = Self.session(
                id: Self.toolSource.sessionID,
                turns: turns,
                toolActivitySource: Self.toolSource)
            let browser = try Self.toolBrowser(session)
            let all = try #require(browser.toolActivityView(for: session))
            #expect(all.turnID == nil)
            #expect(all.source == Self.toolSource)
            let view = try #require(browser.toolActivityView(for: session, turnID: "native-turn"))
            #expect(view.source == Self.toolSource)
            #expect(view.turnID == "native-turn")
            #expect(view.range == browser.context.activityRange)
            let operations = ["native-turn", "tool-only-turn"].map { id in
                SessionToolOperation(
                    id: .init(threadID: Self.toolSource.sessionID, turnID: id, itemID: id),
                    kind: .command,
                    name: "CommandExecution",
                    preview: nil,
                    completedAt: session.lastActivity,
                    outcome: .completed,
                    exitCode: 0,
                    durationMilliseconds: 1,
                    timing: .native,
                    recordOffset: 0,
                    recordLength: 1)
            }
            let snapshot = SessionToolActivitySnapshot(
                source: Self.toolSource,
                operations: operations,
                ignoredRecordCount: 0,
                isPartial: false,
                fileSize: 2,
                modificationDate: session.lastActivity,
                fileNumber: 0)
            #expect(snapshot.operations(in: all.range, turnID: all.turnID).map(\.id.turnID)
                == ["native-turn", "tool-only-turn"])
            #expect(snapshot.operations(in: view.range, turnID: view.turnID).map(\.id.turnID) == ["native-turn"])
        }
    }

    @Test
    func `tool fallback requires a supplied source and reporting range`() throws {
        let withoutSource = Self.session(id: Self.toolSource.sessionID)
        #expect(try Self.toolBrowser(withoutSource).toolActivityView(for: withoutSource) == nil)
        let withSource = Self.session(id: Self.toolSource.sessionID, toolActivitySource: Self.toolSource)
        let withoutRange = try Self.toolBrowser(withSource, range: nil)
        #expect(withoutRange.toolActivityView(for: withSource) == nil)
    }

    private static let toolSource = SessionToolActivitySource(
        fileURL: URL(fileURLWithPath: "/synthetic/rollout.jsonl"),
        sessionID: "tool-session")

    private static func toolTurn(_ id: String?) -> CostUsageSessionTurn {
        CostUsageSessionTurn(
            turnID: id,
            firstActivity: nil,
            lastActivity: nil,
            inputTokens: 120,
            cachedInputTokens: 90,
            outputTokens: 20,
            reasoningTokens: 10,
            totalTokens: 140,
            requestCount: 2,
            costUSD: 0.02)
    }

    private static func toolBrowser(
        _ session: CostUsageSessionBreakdown,
        range: Range<Date>? = Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 10)) throws
        -> SessionUsageBrowser
    {
        let context = try SessionUsageBrowserContext(
            providerName: "Synthetic agent",
            windowLabel: "Synthetic reporting window",
            sessions: [session],
            currencyCode: "USD",
            costMultiplier: 1,
            timeZone: #require(TimeZone(identifier: "Asia/Shanghai")),
            activityRange: range)
        return SessionUsageBrowser(context: context, hidePersonalInfo: true)
    }

    private static func session(
        id: String,
        title: String? = nil,
        activity: TimeInterval = 1,
        cached: Int? = 90,
        total: Int? = 140,
        cost: Double? = 0.02,
        turns: [CostUsageSessionTurn] = [],
        toolActivitySource: SessionToolActivitySource? = nil) -> CostUsageSessionBreakdown
    {
        CostUsageSessionBreakdown(
            sessionID: id,
            lastActivity: Date(timeIntervalSince1970: activity),
            inputTokens: 120,
            cachedInputTokens: cached,
            outputTokens: 20,
            reasoningTokens: 10,
            totalTokens: total,
            requestCount: 2,
            costUSD: cost,
            modelBreakdowns: [],
            title: title,
            turns: turns,
            toolActivitySource: toolActivitySource)
    }
}
