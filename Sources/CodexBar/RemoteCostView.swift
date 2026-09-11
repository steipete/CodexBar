import AppKit
import CodexBarCore
import Foundation
import SwiftUI

enum RemoteCostChartSeries {
    static func summaries(
        reports: [RemoteHostCostReport],
        provider: UsageProvider,
        combinedHosts: Set<String>) -> [RemoteCostSummary]
    {
        reports.compactMap { report in
            guard combinedHosts.contains(report.host), report.provider == provider.rawValue else { return nil }
            return report.summary
        }
    }

    static func daily(
        reports: [RemoteHostCostReport],
        provider: UsageProvider,
        combinedHosts: Set<String>) -> [RemoteCostDailySummary]
    {
        struct Totals {
            var tokens: Int?
            var costUSD: Double?
            var tokenOverflow = false
        }
        var byDate: [String: Totals] = [:]
        for day in self.summaries(reports: reports, provider: provider, combinedHosts: combinedHosts)
            .flatMap(\.daily)
        {
            var totals = byDate[day.date] ?? Totals()
            if let tokens = day.totalTokens, !totals.tokenOverflow {
                if let existing = totals.tokens {
                    let (sum, overflow) = existing.addingReportingOverflow(tokens)
                    totals.tokens = overflow ? nil : sum
                    totals.tokenOverflow = overflow
                } else {
                    totals.tokens = tokens
                }
            }
            if let cost = day.costUSD {
                totals.costUSD = (totals.costUSD ?? 0) + cost
            }
            byDate[day.date] = totals
        }
        return byDate.keys.sorted().compactMap { date in
            guard let totals = byDate[date], totals.tokens != nil || totals.costUSD != nil else { return nil }
            return RemoteCostDailySummary(date: date, totalTokens: totals.tokens, costUSD: totals.costUSD)
        }
    }
}

struct RemoteCostPresentation {
    let title: String
    let lines: [String]

    init(report: RemoteHostCostReport, index: Int, hidePersonalInfo: Bool, now: Date = Date()) {
        let host = hidePersonalInfo ? L("Host %d", index + 1) : report.host
        self.title = "\(host) — \(Self.providerName(report.provider))"
        guard let summary = report.summary else {
            self.lines = [report.error.map { L($0) } ?? L("Refreshing…")]
            return
        }
        func amount(_ cost: Double?, _ tokens: Int?) -> String {
            let costText = cost.map(UsageFormatter.usdString) ?? "—"
            let tokenText = tokens.map(UsageFormatter.tokenCountString) ?? "—"
            return "\(costText) · \(L("%@ tokens", tokenText))"
        }
        self.lines = [
            "\(L("Today")): \(amount(summary.sessionCostUSD, summary.sessionTokens))",
            "\(L("Last %d days", summary.historyDays)): " +
                amount(summary.last30DaysCostUSD, summary.last30DaysTokens),
            L("Day boundaries: %@", summary.bucketTimeZone),
            UsageFormatter.updatedString(from: summary.updatedAt, now: now),
        ] + (summary.historyCoverageIsEstablished ? [] : [L("Partial history; scan is incomplete.")]) +
            (summary.coverage.unpriced > 0 ? [L("Some usage has no known price.")] : []) +
            [Self.disclaimer(report.provider)]
    }

    static func providerName(_ rawValue: String) -> String {
        guard let provider = UsageProvider(rawValue: rawValue) else { return rawValue.capitalized }
        return ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    static func disclaimer(_ provider: String) -> String {
        // Provider-specific by design: Claude subscription estimates require different billing semantics.
        provider == UsageProvider.claude.rawValue
            ? L("Notional API-rate estimate; subscription charges are not measured.")
            : L("API-equivalent estimate; not a subscription bill.")
    }

    static func hostIndex(of report: RemoteHostCostReport, in reports: [RemoteHostCostReport]) -> Int {
        var hosts: [String] = []
        for candidate in reports where !hosts.contains(candidate.host) {
            hosts.append(candidate.host)
        }
        return hosts.firstIndex(of: report.host) ?? 0
    }
}

struct CombinedRemoteCostPresentation: Identifiable {
    let id: String
    let title: String
    let lines: [String]

    init?(
        provider: UsageProvider,
        local: CostUsageTokenSnapshot?,
        reports: [RemoteHostCostReport],
        combinedHosts: Set<String>)
    {
        guard !combinedHosts.isEmpty else { return nil }
        let remote = reports.filter {
            combinedHosts.contains($0.host) && $0.provider == provider.rawValue
        }
        let summaries = remote.compactMap(\.summary)
        let expectedSources = combinedHosts.count + 1
        let availableSources = summaries.count + (local == nil ? 0 : 1)
        let historyDays = local?.historyDays ?? summaries.first?.historyDays ?? 30
        let coverageIsEstablished = local?.historyCoverageIsEstablished == true &&
            summaries.count == combinedHosts.count &&
            summaries.allSatisfy(\.historyCoverageIsEstablished)

        func amount(cost: [Double?], tokens: [Int?]) -> String {
            let knownCosts = cost.compactMap(\.self)
            var costTotal: Double? = knownCosts.isEmpty ? nil : 0
            for value in knownCosts {
                guard let current = costTotal else { break }
                let sum = current + value
                costTotal = sum.isFinite ? sum : nil
            }
            let costText = costTotal.map(UsageFormatter.usdString) ?? "—"
            let knownTokens = tokens.compactMap(\.self)
            var tokenTotal: Int? = knownTokens.isEmpty ? nil : 0
            for value in knownTokens {
                guard let current = tokenTotal else { break }
                let (sum, overflow) = current.addingReportingOverflow(value)
                tokenTotal = overflow ? nil : sum
            }
            let tokenText = tokenTotal.map(UsageFormatter.tokenCountString) ?? "—"
            let complete = knownCosts.count == expectedSources && costTotal != nil &&
                knownTokens.count == expectedSources && tokenTotal != nil && coverageIsEstablished
            return "\(costText) · \(L("%@ tokens", tokenText))" + (complete ? "" : " · \(L("partial"))")
        }

        self.id = provider.rawValue
        self.title = L("Combined — %@", RemoteCostPresentation.providerName(provider.rawValue))
        let todayAmount = amount(
            cost: [local?.sessionCostUSD] + summaries.map(\.sessionCostUSD),
            tokens: [local?.sessionTokens] + summaries.map(\.sessionTokens))
        let historyAmount = amount(
            cost: [local?.last30DaysCostUSD] + summaries.map(\.last30DaysCostUSD),
            tokens: [local?.last30DaysTokens] + summaries.map(\.last30DaysTokens))
        self.lines = [
            L("This Mac + %d selected SSH boxes", combinedHosts.count),
            "\(L("Today (device-local days)")): \(todayAmount)",
            "\(L("Last %d days", historyDays)): \(historyAmount)",
        ] + (availableSources == expectedSources ? [] : [
            L("%d of %d sources are currently available.", availableSources, expectedSources),
        ]) + [
            L("Additive estimate; copied or resumed sessions may be counted more than once."),
            RemoteCostPresentation.disclaimer(provider.rawValue),
        ]
    }
}

@MainActor
struct RemoteCostView: View {
    @Bindable var costs: RemoteCostStore
    let hidePersonalInfo: Bool
    var localSnapshots: [UsageProvider: CostUsageTokenSnapshot] = [:]
    var combinedHosts: Set<String> = []

    var body: some View {
        if !self.costs.reports.isEmpty || self.costs.configurationError != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("SSH device costs")).font(.headline)
                    if self.costs.isRefreshing { ProgressView().controlSize(.small) }
                }
                Text(L("Per-host estimates stay separate from local totals and from each other."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = self.costs.configurationError {
                    Text(L(error)).font(.callout)
                }
                ForEach(RemoteCostFetcher.supportedProviders, id: \.self) { provider in
                    if let model = CombinedRemoteCostPresentation(
                        provider: provider,
                        local: self.localSnapshots[provider],
                        reports: self.costs.reports,
                        combinedHosts: self.combinedHosts)
                    {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.title).font(.subheadline.weight(.semibold))
                            ForEach(model.lines, id: \.self) { line in
                                Text(line).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                ForEach(self.costs.reports) { report in
                    let model = RemoteCostPresentation(
                        report: report,
                        index: RemoteCostPresentation.hostIndex(of: report, in: self.costs.reports),
                        hidePersonalInfo: self.hidePersonalInfo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title).font(.subheadline.weight(.semibold))
                        ForEach(model.lines, id: \.self) { line in
                            Text(line).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
struct RemoteCostHostsEditor: View {
    @Bindable var settings: SettingsStore
    @State private var hosts = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: self.$settings.remoteCostsEnabled) {
                Text(L("Fetch costs from SSH devices"))
            }
            LabeledContent(L("Remote costs over SSH")) {
                TextField(L("SSH hosts"), text: self.$hosts, prompt: Text("ubuntu, user@host"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .onSubmit(self.apply)
                Button(L("Apply"), action: self.apply)
                    .disabled(self.hosts == self.settings.remoteCostHosts)
            }
            .disabled(!self.settings.remoteCostsEnabled)
            if self.settings.remoteCostsEnabled, !self.configuredHosts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Combined totals")).font(.subheadline.weight(.medium))
                    ForEach(self.configuredHosts, id: \.self) { host in
                        Toggle(isOn: self.combinedBinding(for: host)) {
                            Text(L("Include %@ with this Mac", host))
                        }
                    }
                    ColorPicker(
                        L("SSH chart color"),
                        selection: self.chartColorBinding,
                        supportsOpacity: false)
                    Text(L("Enable only when that box uses the same provider account. " +
                            "Individual device totals always remain visible."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L("Reads Claude and Codex summaries over SSH using your existing SSH configuration. " +
                    "Remote hosts need an updated CodexBar CLI. Cost-only; this does not use Agent Sessions. " +
                    "Disable the toggle to stop connecting."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { self.hosts = self.settings.remoteCostHosts }
        .onChange(of: self.settings.remoteCostHosts) { _, value in self.hosts = value }
    }

    private func apply() {
        do {
            let hosts = try RemoteCostFetcher.hosts(from: self.hosts)
            self.settings.remoteCostHosts = hosts.joined(separator: ", ")
            let retainedCombinedHosts = self.combinedHosts.filter(hosts.contains)
            self.settings.remoteCostCombinedHosts = retainedCombinedHosts.sorted().joined(separator: ", ")
            self.hosts = self.settings.remoteCostHosts
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var configuredHosts: [String] {
        (try? RemoteCostFetcher.hosts(from: self.settings.remoteCostHosts)) ?? []
    }

    private var combinedHosts: Set<String> {
        Set((try? RemoteCostFetcher.hosts(from: self.settings.remoteCostCombinedHosts)) ?? [])
    }

    private func combinedBinding(for host: String) -> Binding<Bool> {
        Binding(
            get: { self.combinedHosts.contains(host) },
            set: { enabled in
                var hosts = self.combinedHosts
                if enabled {
                    hosts.insert(host)
                } else {
                    hosts.remove(host)
                }
                self.settings.remoteCostCombinedHosts = hosts.sorted().joined(separator: ", ")
            })
    }

    private var chartColorBinding: Binding<Color> {
        Binding(
            get: {
                let color = self.settings.remoteCostChartColor
                return Color(red: color.red, green: color.green, blue: color.blue)
            },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                self.settings.remoteCostChartColor = ProviderColor(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent))
            })
    }
}
