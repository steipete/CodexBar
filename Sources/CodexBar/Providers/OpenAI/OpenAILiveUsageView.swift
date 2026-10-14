import Charts
import CodexBarCore
import SwiftUI

struct OpenAILiveUsageView: View {
    @Bindable var model: OpenAILiveUsageModel
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.header
            if let error = self.model.lastError {
                HStack {
                    if self.model.isRateLimited {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(L("Rate limited; retrying in %ds", self.retrySeconds(at: context.date)))
                        }
                    } else {
                        Text(error)
                    }
                    Spacer(minLength: 0)
                    if self.model.isMissingCredential {
                        Button(L("Open OpenAI Settings"), action: self.openSettings)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if let snapshot = self.model.snapshot {
                self.metrics(snapshot)
                OpenAILiveUsageChart(
                    snapshot: snapshot,
                    filter: self.model.filter,
                    tpmLimit: snapshot.utilization(for: self.model.filter, limits: self.model.limits)?
                        .limit.tokensPerMinute)
                    .frame(minHeight: 140, idealHeight: 220, maxHeight: 260)
                if snapshot.summary(for: self.model.filter).totalTokens == 0 {
                    Text(L("No API traffic in this window"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                OpenAILiveUsageTable(
                    snapshot: snapshot,
                    limits: self.model.limits,
                    filter: self.$model.filter)
                self.footer(projectID: snapshot.projectID)
            } else {
                Spacer()
                if self.model.isLoading {
                    ProgressView(L("Loading live usage…"))
                        .frame(maxWidth: .infinity)
                } else if self.model.lastError == nil {
                    Text(L("No API traffic in this window"))
                        .frame(maxWidth: .infinity)
                }
                Spacer()
                self.footer(projectID: nil)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker(L("Model"), selection: self.$model.filter) {
                Text(L("All models")).tag(OpenAILiveUsageModelFilter.allModels)
                Divider()
                ForEach(self.selectableModels, id: \.self) { name in
                    Text(name).tag(OpenAILiveUsageModelFilter.model(name))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            Spacer(minLength: 0)
            Picker(L("Range"), selection: self.$model.windowMinutes) {
                Text(L("15m")).tag(15)
                Text(L("1h")).tag(60)
                Text(L("6h")).tag(360)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let updated = self.model.lastUpdated {
                    Text(Self.updatedText(from: updated, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button(L("Limits…"), action: self.openSettings)
            Button(action: { self.model.refresh() }, label: {
                if self.model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            })
            .help(L("Refresh"))
            .accessibilityLabel(L("Refresh"))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(self.model.isLoading)
        }
    }

    private var selectableModels: [String] {
        var names = self.model.snapshot?.modelNames ?? []
        if case let .model(name) = self.model.filter, !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private func metrics(_ snapshot: OpenAILiveUsageSnapshot) -> some View {
        let summary = snapshot.summary(for: self.model.filter)
        let utilization = snapshot.utilization(for: self.model.filter, limits: self.model.limits)
        return HStack(alignment: .top, spacing: 12) {
            self.metric(
                summary.latestMinuteStart.map { L("Latest · %@", $0.formatted(date: .omitted, time: .shortened)) }
                    ?? L("Latest"),
                value: summary.latestTPM,
                detail: "TPM",
                percent: utilization?.latestTPMPercent)
            self.metric(L("5-min avg"), value: Int(summary.fiveMinuteAverageTPM), detail: "TPM")
            self.metric(
                L("Peak"),
                value: summary.peakTPM,
                detail: "TPM" + " · " +
                    (summary.peakMinuteStart?.formatted(date: .omitted, time: .shortened) ?? "—"),
                percent: utilization?.peakTPMPercent)
            self.metric(
                L("Tokens in window"),
                value: summary.totalTokens,
                detail: L(
                    "Input %@ · cached %@ · output %@",
                    Self.count(summary.inputTokens),
                    Self.count(summary.cachedInputTokens),
                    Self.count(summary.outputTokens)),
                batchDetail: summary.batchTokens > 0 ?
                    L("Batch API %@ · not counted in %% of limit", Self.count(summary.batchTokens)) : nil)
            self.metric(L("Requests in window"), value: summary.requests, detail: "")
            // Org limits don't apply to a project's slice of traffic; the footer names the project.
            if snapshot.projectID == nil, case let .model(name) = self.model.filter {
                self.limitTile(utilization, projectCap: self.model.limits.projectCap(for: name))
            } else if let highest = snapshot.highestUtilization(limits: self.model.limits),
                      let percent = highest.peakTPMPercent
            {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Highest utilization")).font(.caption).foregroundStyle(.secondary)
                    Text("\(highest.name) · \(Self.percent(percent))")
                        .font(.callout).foregroundStyle(Self.utilizationColor(percent))
                }
            }
        }
    }

    private func metric(
        _ title: String, value: Int, detail: String, percent: Double? = nil, batchDetail: String? = nil) -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Self.count(value)).font(.title2).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let batchDetail {
                Text(batchDetail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let percent {
                Text(L("%@ of limit", Self.percent(percent)))
                    .font(.caption2).foregroundStyle(Self.utilizationColor(percent))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func limitTile(
        _ utilization: OpenAIOrgLimitUtilization?, projectCap: OpenAIOrgRateLimits.Limit?) -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Limit")).font(.caption).foregroundStyle(.secondary)
            if let utilization {
                Text(Self.limitText(utilization.limit)).font(.callout).monospacedDigit()
                if let percent = utilization.peakRPMPercent {
                    Text(L("Peak RPM: %@ of limit", Self.percent(percent)))
                        .font(.caption2).foregroundStyle(Self.utilizationColor(percent))
                }
            } else {
                Text(L("Org limit not set")).font(.callout)
            }
            if let projectCap {
                Text(L("project cap %@", Self.count(projectCap.tokensPerMinute)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if utilization == nil {
                Button(L("Set org limit…"), action: self.openSettings)
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    static func limitText(_ limit: OpenAIOrgRateLimits.Limit) -> String {
        var text = ProviderRateLimitNumber.format(limit.tokensPerMinute) + " TPM"
        if let rpm = limit.requestsPerMinute { text += " · " + ProviderRateLimitNumber.format(rpm) + " RPM" }
        return text
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    static func utilizationColor(_ percent: Double) -> Color {
        if percent >= 95 { return Color(nsColor: .systemRed) }
        if percent >= 80 { return Color(nsColor: .systemOrange) }
        return .secondary
    }

    private func footer(projectID: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("OpenAI Admin Usage API · 1-minute buckets · the newest minute can arrive late"))
            if let projectID { Text(L("Project: %@", projectID)) }
            Text(L("Org limits come from Settings — OpenAI's API doesn't expose them."))
            if let caps = self.model.projectCaps {
                Text(L(
                    "Project caps are the highest per-project limit across %d active projects; " +
                        "org-wide traffic can exceed them.",
                    caps.projectsSampled))
                if caps.truncated { Text(L("Project sample capped at 25; higher project caps may exist.")) }
            }
            if let error = self.model.limitsError {
                Text(L("Project caps unavailable")).help(error)
            }
            Text(L("% of limit counts all input, including cached input, plus output, as OpenAI's rate limiter does, " +
                    "and excludes Batch API traffic, which has separate limits. " +
                    "The limiter also reserves max_tokens up front, so short bursts can still hit limits."))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func retrySeconds(at date: Date) -> Int {
        max(0, Int(ceil(self.model.nextRefreshAt?.timeIntervalSince(date) ?? self.model.pollingInterval)))
    }

    static func updatedText(from updated: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updated))
        if seconds < 60 { return L("Updated just now") }
        if seconds < 3600 { return L("Updated %@m ago", String(Int(seconds / 60))) }
        return L("Updated %@h ago", String(Int(seconds / 3600)))
    }

    static func count(_ value: Int) -> String {
        UsageFormatter.tokenCountString(value)
    }
}

private struct OpenAILiveUsageTable: View {
    let snapshot: OpenAILiveUsageSnapshot
    let limits: OpenAIOrgLimitResolver
    @Binding var filter: OpenAILiveUsageModelFilter
    private let limitColumnWidth: CGFloat = 115

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Model")).frame(maxWidth: .infinity, alignment: .leading)
                self.cell(L("Latest TPM"))
                self.cell(L("Peak TPM"))
                self.cell(L("Tokens"))
                self.cell(L("Requests"))
                Text(L("Org TPM limit")).frame(width: self.limitColumnWidth, alignment: .trailing)
                self.cell(L("Peak % of limit"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    self.row(L("All models"), filter: .allModels)
                    ForEach(self.snapshot.modelNames, id: \.self) { name in
                        self.row(name, filter: .model(name))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minHeight: 85, maxHeight: .infinity)
    }

    private func row(_ name: String, filter: OpenAILiveUsageModelFilter) -> some View {
        let summary = self.snapshot.summary(for: filter)
        let utilization = self.snapshot.utilization(for: filter, limits: self.limits)
        return HStack {
            Button { self.filter = filter } label: {
                Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            self.cell(OpenAILiveUsageView.count(summary.latestTPM))
            self.cell(OpenAILiveUsageView.count(summary.peakTPM))
            self.cell(OpenAILiveUsageView.count(summary.totalTokens))
            self.cell(OpenAILiveUsageView.count(summary.requests))
            VStack(alignment: .trailing, spacing: 2) {
                Text(utilization.map { ProviderRateLimitNumber.format($0.limit.tokensPerMinute) } ?? "—")
                if case let .model(model) = filter, let cap = self.limits.projectCap(for: model) {
                    Text(L("project cap %@", OpenAILiveUsageView.count(cap.tokensPerMinute)))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(width: self.limitColumnWidth, alignment: .trailing)
            self.capacity(utilization?.peakTPMPercent)
        }
        .padding(8)
        .contentShape(Rectangle())
        .background(self.filter == filter ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { self.filter = filter }
        .accessibilityAddTraits(self.filter == filter ? .isSelected : [])
    }

    private func capacity(_ percent: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(percent.map(OpenAILiveUsageView.percent) ?? "—").monospacedDigit()
            if let percent {
                GeometryReader { geometry in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(OpenAILiveUsageView.utilizationColor(percent))
                                .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                        }
                }.frame(height: 3)
            }
        }.frame(width: 85, alignment: .trailing)
    }

    private func cell(_ text: String) -> some View {
        Text(text).monospacedDigit().frame(width: 85, alignment: .trailing)
    }
}
