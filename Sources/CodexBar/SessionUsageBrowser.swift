import AppKit
import CodexBarCore
import Observation
import SwiftUI

struct SessionUsageBrowserContext: Sendable {
    let providerName: String
    let windowLabel: String
    let sessions: [CostUsageSessionBreakdown]
    let currencyCode: String
    let costMultiplier: Double
    let timeZone: TimeZone
    var activityRange: Range<Date>?
}

/// Menu navigation carries the exact account snapshot into the existing Usage & Spend pane.
@MainActor
@Observable
final class SessionUsageNavigation {
    static let shared = SessionUsageNavigation()
    struct Request: Identifiable, Sendable {
        let id = UUID()
        let context: SessionUsageBrowserContext
        let sessionID: String?
    }

    var request: Request?
}

@MainActor
struct SessionUsageBrowser: View {
    let context: SessionUsageBrowserContext
    let hidePersonalInfo: Bool
    @State private var query = ""
    @State private var sort = SessionUsagePresentation.Sort.activity
    @State private var ascending = false
    @State private var selectedSessionID: String?
    @State private var requestDetails: (key: DetailKey, turns: [CostUsageSessionTurn])?
    @State private var loadingDetails = false
    @State private var detailError: CostUsageSessionDetailError?

    private struct DetailKey: Hashable {
        let source: CostUsageSessionDetailSource?
        let sessionID: String?
        let lastActivity: Date?
        let costUSD: Double?
        let range: Range<Date>?
        let timeZone: String
    }

    init(context: SessionUsageBrowserContext, hidePersonalInfo: Bool, selectedSessionID: String? = nil) {
        self.context = context
        self.hidePersonalInfo = hidePersonalInfo
        self._selectedSessionID = State(initialValue: selectedSessionID)
    }

    private var sessions: [CostUsageSessionBreakdown] {
        SessionUsagePresentation.sessions(
            self.context.sessions,
            matching: self.query,
            hidePersonalInfo: self.hidePersonalInfo,
            sort: self.sort,
            ascending: self.ascending)
    }

    private var selectedSession: CostUsageSessionBreakdown? {
        guard let session = self.sessions.first(where: { $0.sessionID == self.selectedSessionID }) ?? self.sessions
            .first
        else { return nil }
        guard let details = self.requestDetails, details.key == self.detailKey(for: session)
        else { return session }
        return session.withRequestDetails(details.turns)
    }

    private var detailKey: DetailKey {
        self.detailKey(for: self.selectedSession)
    }

    private func detailKey(for session: CostUsageSessionBreakdown?) -> DetailKey {
        DetailKey(
            source: session?.requestDetailSource,
            sessionID: session?.sessionID,
            lastActivity: session?.lastActivity,
            costUSD: session?.costUSD,
            range: self.context.activityRange,
            timeZone: self.context.timeZone.identifier)
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 600 {
                VStack(spacing: 0) {
                    self.sessionList.frame(height: 190)
                    Divider()
                    self.detailPane
                }
            } else {
                HSplitView {
                    self.sessionList.frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                    self.detailPane.frame(minWidth: 320)
                }
            }
        }
        .onAppear {
            if self.selectedSessionID == nil { self.selectedSessionID = self.sessions.first?.sessionID }
        }
        .onChange(of: self.sessions.map(\.sessionID)) { _, ids in
            if !ids.contains(self.selectedSessionID ?? "") { self.selectedSessionID = ids.first }
        }
        .onChange(of: self.hidePersonalInfo) { _, _ in
            self.query = ""
        }
        .environment(\.timeZone, self.context.timeZone)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            TextField(L("Search sessions"), text: self.$query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            HStack {
                Picker(L("Sort by"), selection: self.$sort) {
                    ForEach(SessionUsagePresentation.Sort.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                .labelsHidden()
                Button { self.ascending.toggle() } label: {
                    Image(systemName: self.ascending ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.borderless)
                .help(L(self.ascending ? "Ascending" : "Descending"))
                .accessibilityLabel(L(self.ascending ? "Ascending" : "Descending"))
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            List(selection: self.$selectedSessionID) {
                ForEach(self.sessions) { session in
                    self.sessionRow(session)
                        .tag(session.sessionID)
                }
            }
            .overlay {
                if self.sessions.isEmpty {
                    ContentUnavailableView(L("No matching sessions"), systemImage: "magnifyingglass")
                }
            }
        }
    }

    private var detailPane: some View {
        Group {
            if let session = self.selectedSession {
                self.details(session)
            } else {
                ContentUnavailableView(L("Select a session"), systemImage: "text.bubble")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: self.detailKey) { await self.loadSelectedDetails() }
        .onDisappear { self.requestDetails = nil }
    }

    private func loadSelectedDetails() async {
        guard !Task.isCancelled else { return }
        self.requestDetails = nil
        self.detailError = nil
        self.loadingDetails = false
        guard let session = self.selectedSession, let source = session.requestDetailSource,
              let range = self.context.activityRange else { return }
        let key = self.detailKey(for: session)
        self.loadingDetails = true
        do {
            let details = try await CostUsageSessionDetailLoader.load(
                source: source,
                lastActivity: session.lastActivity,
                range: range,
                timeZone: self.context.timeZone)
            try Task.checkCancellation()
            self.requestDetails = (key, details)
            self.loadingDetails = false
        } catch is CancellationError {
            // Selection changes cancel queued/in-flight work and release the previous result.
        } catch {
            guard !Task.isCancelled else { return }
            self.detailError = error as? CostUsageSessionDetailError ?? .unavailable
            self.loadingDetails = false
        }
    }

    private func sessionRow(_ session: CostUsageSessionBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.identity(session).name)
                .fontWeight(.medium)
                .lineLimit(1)
                .help(self.identity(session).name)
            HStack {
                Text(self.tokenText(session.totalTokens))
                Spacer(minLength: 6)
                Text(self.costText(session.costUSD))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(self.dateText(session.lastActivity))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func details(_ session: CostUsageSessionBreakdown) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(self.identity(session).name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    if !self.hidePersonalInfo {
                        Text(session.sessionID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("\(self.context.providerName) · \(self.context.windowLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(self.dateText(session.lastActivity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if self.hidePersonalInfo {
                        Label(L("hide_personal_info_title"), systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 18) {
                    GridRow {
                        self.metric(L("Input"), value: self.tokenText(session.inputTokens))
                        self.metric(L("Cached input"), value: self.tokenText(session.cachedInputTokens))
                    }
                    GridRow {
                        self.metric(L("Uncached input"), value: self.tokenText(
                            SessionUsagePresentation.uncachedInput(session)))
                        self.metric(L("Output"), value: self.tokenText(session.outputTokens))
                    }
                    GridRow {
                        self.metric(L("Reasoning"), value: self.tokenText(session.reasoningTokens))
                        self.metric(L("Requests"), value: self.tokenText(session.requestCount))
                    }
                    GridRow {
                        self.metric(L("Total"), value: self.tokenText(session.totalTokens))
                        self.metric(L("Estimated spend"), value: self.costText(session.costUSD))
                    }
                }

                Text(L("Cached input is included in input; reasoning is included in output."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L(UsageFormatter.costEstimateHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let performance = CostUsageTurnPerformanceSummary(samples: session.turnPerformanceSamples) {
                    SpendSessionPerformanceView(summary: performance)
                }

                Divider()
                Text(L("spend_performance_turns")).font(.headline)
                Text(L("Each turn includes its recorded model calls within this period. " +
                        "Messages sharing a turn cannot be priced separately."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if self.loadingDetails {
                    ProgressView().controlSize(.small)
                } else if let error = self.detailError {
                    Text(L(error == .limitExceeded
                            ? "Request details exceed the limit."
                            : "Request details are unavailable. Refresh usage and try again."))
                        .font(.callout).foregroundStyle(.secondary)
                } else if session.turns.isEmpty {
                    Text(L("No turn-level usage records are available."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(session.turns.enumerated()), id: \.element.id) { index, turn in
                    self.turnRow(turn, index: index, session: session)
                }

                if let activity = self.toolActivityView(for: session) {
                    Divider()
                    activity
                    Text(L("Tool activity has no separate recorded token or monetary cost."))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if !session.modelBreakdowns.isEmpty {
                    Divider()
                    Text(L("Models")).font(.headline)
                    ForEach(Array(session.modelBreakdowns.enumerated()), id: \.offset) { _, model in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(UsageFormatter.modelDisplayName(model.modelName))
                                Text(L(
                                    "Input %@ · cached %@ · output %@",
                                    self.tokenText(model.inputTokens),
                                    self.tokenText(model.cacheReadTokens),
                                    self.tokenText(model.outputTokens)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Text(self.costText(model.costUSD)).monospacedDigit()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func toolActivityView(
        for session: CostUsageSessionBreakdown,
        turnID: String? = nil) -> SpendSessionToolActivityView?
    {
        guard let source = session.toolActivitySource, let range = self.context.activityRange else { return nil }
        // Keep an all-operations route: tools can belong to turns with no retained billed request.
        return SpendSessionToolActivityView(
            source: source,
            lastActivity: session.lastActivity,
            range: range,
            timeZone: self.context.timeZone,
            hidePersonalInfo: self.hidePersonalInfo,
            turnID: turnID)
    }

    private func turnRow(_ turn: CostUsageSessionTurn, index: Int, session: CostUsageSessionBreakdown) -> some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    self.metric(L("Input"), value: self.tokenText(turn.inputTokens))
                    self.metric(L("Cached input"), value: self.tokenText(turn.cachedInputTokens))
                }
                GridRow {
                    self.metric(L("Output"), value: self.tokenText(turn.outputTokens))
                    self.metric(L("Reasoning"), value: self.tokenText(turn.reasoningTokens))
                }
                GridRow {
                    self.metric(L("Requests"), value: self.tokenText(turn.requestCount))
                    self.metric(L("Estimated spend"), value: self.costText(turn.costUSD))
                }
            }
            .padding(.vertical, 10)
            if !turn.requests.isEmpty {
                DisclosureGroup(L("Model requests")) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(turn.requests.enumerated()), id: \.element.id) { index, request in
                            self.requestRow(request, index: index)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            if let turnID = turn.turnID,
               let activity = self.toolActivityView(for: session, turnID: turnID)
            {
                activity
                Text(L("Tool activity has no separate recorded token or monetary cost."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.turnID == nil ? L("Unattributed usage") : L("Turn %d", index + 1))
                    if let date = turn.firstActivity {
                        Text(self.dateText(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(self.tokenText(turn.totalTokens)).foregroundStyle(.secondary)
                Text(self.costText(turn.costUSD)).monospacedDigit()
            }
        }
    }

    private func requestRow(_ request: CostUsageSessionRequest, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(L("Request %d", index + 1) + " · " + UsageFormatter.modelDisplayName(request.modelName))
                Spacer(minLength: 8)
                Text(self.costText(request.costUSD)).monospacedDigit()
            }
            Text(L(
                "Input %@ · cached %@ · output %@",
                self.tokenText(request.inputTokens),
                self.tokenText(request.cachedInputTokens),
                self.tokenText(request.outputTokens)))
                .foregroundStyle(.secondary)
            HStack {
                if let date = request.timestamp { Text(self.dateText(date, seconds: true)) }
                Spacer(minLength: 8)
                Text(L("Reasoning") + ": " + self.tokenText(request.reasoningTokens))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identity(_ session: CostUsageSessionBreakdown) -> CostHistoryIdentity {
        CostHistoryIdentity(
            sessionID: session.sessionID,
            title: session.title,
            hidePersonalInfo: self.hidePersonalInfo)
    }

    private func tokenText(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "—" }
        return value.formatted(.number.locale(codexBarLocalizedLocale()))
    }

    private func costText(_ value: Double?) -> String {
        SessionUsagePresentation.costText(
            value,
            multiplier: self.context.costMultiplier,
            currencyCode: self.context.currencyCode)
    }

    private func dateText(_ date: Date, seconds: Bool = false) -> String {
        var format = Date.FormatStyle.dateTime.year().month().day().hour().minute()
        if seconds { format = format.second() }
        format.locale = codexBarLocalizedLocale()
        format.timeZone = self.context.timeZone
        return date.formatted(format)
    }
}
