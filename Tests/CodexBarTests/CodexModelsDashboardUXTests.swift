import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite("Codex Models dashboard UX")
struct CodexModelsDashboardUXTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    @Test
    @MainActor
    func `search reports when it hides the selected model`() {
        let intervals = self.intervals(days: 7)
        let model = CodexModelsDashboardModel(snapshot: self.build(
            current: [
                self.fragment(day: intervals.current.start, model: "model-a", input: 10),
                self.fragment(day: intervals.current.start, model: "model-b", input: 20),
            ],
            intervals: intervals,
            generatedAt: intervals.current.end))
        model.selectModel("model-b")
        model.searchText = "model-a"

        #expect(model.selectedModelIsHiddenBySearch)
        model.searchText = ""
        #expect(!model.selectedModelIsHiddenBySearch)
    }

    @Test
    @MainActor
    func `responsive profiles preserve known cost while shedding secondary columns`() {
        let wide = CodexModelsTableColumnProfile.resolve(
            layout: .wide,
            metric: .tokens,
            showsEstimatedCost: true)
        let medium = CodexModelsTableColumnProfile.resolve(
            layout: .medium,
            metric: .tokens,
            showsEstimatedCost: true)
        let compact = CodexModelsTableColumnProfile.resolve(
            layout: .compact,
            metric: .tokens,
            showsEstimatedCost: true)
        let activeCost = CodexModelsTableColumnProfile.resolve(
            layout: .wide,
            metric: .knownCost,
            showsEstimatedCost: true)

        #expect(wide == CodexModelsTableColumnProfile(
            showsSessionReferences: true,
            showsDelta: true,
            showsKnownCost: true,
            showsColumnMenu: true))
        #expect(medium == CodexModelsTableColumnProfile(
            showsSessionReferences: false,
            showsDelta: true,
            showsKnownCost: true,
            showsColumnMenu: false))
        #expect(compact == CodexModelsTableColumnProfile(
            showsSessionReferences: false,
            showsDelta: false,
            showsKnownCost: true,
            showsColumnMenu: false))
        #expect(!activeCost.showsKnownCost)
        #expect(CodexModelsSelectionPresentation.resolve(layout: .wide) == .inspector)
        #expect(CodexModelsSelectionPresentation.resolve(layout: .medium) == .inspector)
        #expect(CodexModelsSelectionPresentation.resolve(layout: .compact) == .sheet)
    }

    @Test
    @MainActor
    func `cost metric is unavailable without priced tokens and falls back atomically`() {
        let intervals = self.intervals(days: 7)
        let unavailable = self.build(
            current: [self.fragment(
                day: intervals.current.start,
                model: "model-a",
                input: 10,
                costNanos: nil)],
            intervals: intervals,
            generatedAt: intervals.current.end)
        let priced = self.build(
            current: [self.fragment(
                day: intervals.current.start,
                model: "model-a",
                input: 10,
                costNanos: 100_000_000)],
            intervals: intervals,
            generatedAt: intervals.current.end)
        let model = CodexModelsDashboardModel(snapshot: unavailable)

        #expect(!model.costMetricIsAvailable)
        model.setMetric(.knownCost)
        #expect(model.metric == .tokens)
        model.replaceSnapshot(priced)
        #expect(model.costMetricIsAvailable)
        model.setMetric(.knownCost)
        #expect(model.metric == .knownCost)
        model.replaceSnapshot(unavailable)
        #expect(model.metric == .tokens)
    }

    @Test
    @MainActor
    func `partial final bucket is excluded from completed peak insight`() throws {
        let intervals = self.intervals(days: 7)
        let secondDay = try #require(self.calendar.date(byAdding: .day, value: 1, to: intervals.current.start))
        let thirdDay = try #require(self.calendar.date(byAdding: .day, value: 2, to: intervals.current.start))
        let generatedAt = try #require(self.calendar.date(byAdding: .hour, value: 12, to: thirdDay))
        let model = CodexModelsDashboardModel(snapshot: self.build(
            current: [
                self.fragment(day: intervals.current.start, model: "model-a", input: 30),
                self.fragment(day: secondDay, model: "model-a", input: 10),
                self.fragment(day: thirdDay, model: "model-a", input: 100),
            ],
            intervals: intervals,
            generatedAt: generatedAt,
            currentIsComplete: false))

        let timeline = model.timelineData

        #expect(timeline.completedPlottedBuckets.map(\.tokens) == [30, 10])
        #expect(timeline.inProgressBucket?.tokens == 100)
        #expect(timeline.peakBucket?.tokens == 30)
        #expect(try abs(#require(timeline.changeFromPeak) - (-2.0 / 3.0)) < 0.0001)
    }

    @Test
    func `protected CSV structurally removes adversarial personal identifiers`() throws {
        let rawPath = "/Users/private.person/Developer/Secret,Workspace"
        let rawTitle = "Confidential \"acquisition\" planning"
        let scopeID = "scope,quoted\"\r\n\(rawPath)"
        let sessionIDs = [
            "comma,marker",
            "quote\"marker",
            "carriage\rreturn",
            "line\nfeed",
            rawPath,
            rawTitle,
        ]
        let intervals = self.intervals(days: 7)
        let snapshot = self.build(
            current: sessionIDs.map {
                self.fragment(
                    day: intervals.current.start,
                    model: "gpt-5",
                    input: 10,
                    workspaceID: scopeID,
                    sessionID: $0)
            },
            intervals: intervals,
            generatedAt: intervals.current.end,
            scopeID: scopeID)

        let protectedCSV = CodexModelsPresentationCSVExporter.export(
            snapshot: snapshot,
            rows: snapshot.rows,
            metric: .tokens,
            hidePersonalInfo: true)
        let normalCSV = CodexModelsPresentationCSVExporter.export(
            snapshot: snapshot,
            rows: snapshot.rows,
            metric: .tokens,
            hidePersonalInfo: false)
        let protectedRecords = self.parseCSV(protectedCSV)
        let normalRecords = self.parseCSV(normalCSV)
        let protectedSnapshot = try #require(CodexModelsPresentationCSVExporter.protectedSnapshot(snapshot))

        #expect(protectedRecords.count == 2)
        #expect(normalRecords.count == 2)
        #expect(protectedRecords[0] == normalRecords[0])
        #expect(protectedRecords[0].count == 32)
        #expect(protectedRecords.allSatisfy { $0.count == protectedRecords[0].count })
        #expect(normalRecords.allSatisfy { $0.count == normalRecords[0].count })
        #expect(protectedRecords[1][0] == "hidden_workspace")
        #expect(protectedRecords[1][6].isEmpty)
        #expect(normalRecords[1][0] == scopeID)
        for sentinel in sessionIDs {
            #expect(normalRecords[1][6].contains(sentinel))
            #expect(!protectedCSV.contains(sentinel))
        }
        #expect(!protectedCSV.contains(scopeID))

        for column in protectedRecords[0].indices where column != 0 && column != 6 {
            #expect(protectedRecords[1][column] == normalRecords[1][column])
        }

        #expect(protectedSnapshot.scopeID == "hidden_workspace")
        #expect(protectedSnapshot.generatedAt == snapshot.generatedAt)
        #expect(protectedSnapshot.indexRevision == snapshot.indexRevision)
        #expect(protectedSnapshot.currentInterval == snapshot.currentInterval)
        #expect(protectedSnapshot.previousInterval == snapshot.previousInterval)
        #expect(protectedSnapshot.currentIsComplete == snapshot.currentIsComplete)
        #expect(protectedSnapshot.previousIsComplete == snapshot.previousIsComplete)
        #expect(protectedSnapshot.totalTokens == snapshot.totalTokens)
        #expect(protectedSnapshot.cost == snapshot.cost)
        #expect(protectedSnapshot.activeModelCount == snapshot.activeModelCount)
        #expect(protectedSnapshot.previousActiveModelCount == snapshot.previousActiveModelCount)
        #expect(protectedSnapshot.newlyActiveModelCount == snapshot.newlyActiveModelCount)
        #expect(protectedSnapshot.uniqueSessionCount == snapshot.uniqueSessionCount)
        #expect(protectedSnapshot.sessionReferenceTotal == snapshot.sessionReferenceTotal)
        #expect(protectedSnapshot.previousSessionReferenceTotal == snapshot.previousSessionReferenceTotal)
        #expect(protectedSnapshot.tokenComparison == snapshot.tokenComparison)
        #expect(protectedSnapshot.costComparison == snapshot.costComparison)
        #expect(protectedSnapshot.sessionReferenceComparison == snapshot.sessionReferenceComparison)
        #expect(protectedSnapshot.daily == snapshot.daily)
        #expect(protectedSnapshot.dailyByModel == snapshot.dailyByModel)
        #expect(protectedSnapshot.diagnostics == snapshot.diagnostics)
        #expect(protectedSnapshot.rows.count == snapshot.rows.count)
        #expect(protectedSnapshot.rows.allSatisfy { $0.associatedSessionIDs == nil })
    }

    private func parseCSV(_ csv: String) -> [[String]] {
        let characters = Array(csv)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var isQuoted = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if isQuoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 2
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                record.append(field)
                field = ""
            } else if character == "\r" || character == "\n", !isQuoted {
                record.append(field)
                records.append(record)
                record = []
                field = ""
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
            } else {
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    private func build(
        current: [CodexModelsUsageFragment],
        intervals: (current: DateInterval, previous: DateInterval),
        generatedAt: Date,
        currentIsComplete: Bool = true,
        scopeID: String? = nil) -> CodexModelsAnalyticsSnapshot
    {
        CodexModelsAnalyticsBuilder().build(CodexModelsAnalyticsRequest(
            source: CodexModelsAnalyticsSource(current: current, previous: []),
            scopeID: scopeID,
            periods: CodexModelsAnalyticsPeriods(current: intervals.current, previous: intervals.previous),
            revision: CodexModelsAnalyticsRevision(generatedAt: generatedAt, indexRevision: "dashboard-ux-fixture"),
            legacy: CodexModelsLegacyBaseline(
                totalTokens: current.reduce(0) { $0 + $1.totalTokens },
                modelIDs: Array(Set(current.map(\.rawModelID)))),
            currentIsComplete: currentIsComplete,
            previousIsComplete: true))
    }

    private func intervals(days: Int) -> (current: DateInterval, previous: DateInterval) {
        let end = self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16))!
        let currentStart = self.calendar.date(byAdding: .day, value: -days, to: end)!
        let previousStart = self.calendar.date(byAdding: .day, value: -days, to: currentStart)!
        return (
            DateInterval(start: currentStart, end: end),
            DateInterval(start: previousStart, end: currentStart))
    }

    private func fragment(
        day: Date,
        model: String,
        input: Int64,
        costNanos: Int64? = 100_000_000,
        workspaceID: String = "workspace",
        sessionID: String? = nil) -> CodexModelsUsageFragment
    {
        CodexModelsUsageFragment(
            workspaceID: workspaceID,
            sessionID: sessionID ?? "session-\(model)",
            day: day,
            timestamp: nil,
            rawModelID: model,
            inputTokens: input,
            cachedInputTokens: 0,
            outputTokens: 0,
            costNanos: costNanos)
    }
}
