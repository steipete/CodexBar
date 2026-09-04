import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    private static let costSupportedProviders = Set(
        ProviderDescriptorRegistry.all.filter(\.cli.supportsCostCommand).map(\.id))

    static func runCost(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = CodexBarCLI.loadConfig(output: output)
        let selection = CodexBarCLI.decodeProvider(from: values, config: config)
        let providers = Self.costProviders(from: selection)
        let unsupported = selection.asList.filter { !Self.costSupportedProviders.contains($0) }
        if !unsupported.isEmpty {
            let names = unsupported
                .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
                .sorted()
                .joined(separator: ", ")
            if !output.jsonOnly {
                Self.writeStderr("Skipping providers without local cost usage: \(names)\n")
            }
        }
        guard !providers.isEmpty else {
            Self.exit(
                code: .failure,
                message: "Error: cost is only supported for \(Self.costSupportedProviderNames()).",
                output: output,
                kind: .args)
        }

        let format = output.format
        let forceRefresh = values.flags.contains("refresh")
        let includeBreakdown = values.flags.contains("breakdown")
        let includePiSessions = Self.decodeCostIncludePiSessions(from: values)
        let useColor = Self.shouldUseColor(noColor: values.flags.contains("noColor"), format: format)
        let historyDays = Self.decodeCostHistoryDays(from: values)
        // Cursor cost reuses the same cookie-source policy as usage fetches: reject the fetch when the
        // user set Cursor cookies to Off, and forward the Manual header so the dashboard request uses
        // the configured session instead of auto-resolving a different one.
        let cursorCookieSettings: ProviderSettingsSnapshot.CursorProviderSettings?
        let cursorCookieSettingsError: Error?
        do {
            cursorCookieSettings = try Self.cursorCookieSettings(config: config, providers: providers)
            cursorCookieSettingsError = nil
        } catch {
            cursorCookieSettings = nil
            cursorCookieSettingsError = error
        }
        let groupBy = Self.decodeCostGroupBy(from: values)
        Self.warnSkippedGroupingProviders(groupBy: groupBy, providers: providers, jsonOnly: output.jsonOnly)
        // Provider-specific by design: this warning applies only when Codex is among the requested providers.
        if providers.contains(.codex),
           !output.jsonOnly,
           let warning = Self.sessionGroupingPiOmissionWarning(
               provider: .codex,
               groupBy: groupBy,
               format: format,
               includePiSessions: includePiSessions)
        {
            Self.writeStderr("Warning: \(warning)\n")
        }

        let bucketCalendar = CostUsageBucketTimeZone.calendar(
            identifier: Self.stringFromAppDefaults("tokenCostUsageBucketTimeZone"))
        let fetcher = CostUsageFetcher(calendar: bucketCalendar)
        var sections: [String] = []
        var payload: [CostPayload] = []
        var exitCode: ExitCode = .success

        // Provider-specific by design: project/session grouping is available only for Codex local session data.
        for provider in Self.costProviders(providers, groupBy: groupBy, format: format) {
            if let error = Self.cursorCostAvailabilityError(
                provider,
                settings: cursorCookieSettings,
                resolutionError: cursorCookieSettingsError)
            {
                exitCode = Self.mapError(error)
                if format == .json {
                    payload.append(Self.makeCostPayload(provider: provider, snapshot: nil, error: error))
                } else if !output.jsonOnly {
                    Self.writeStderr("Error: \(error.localizedDescription)\n")
                }
                continue
            }
            do {
                // Claude/Codex cost comes from local logs; Cursor cost is fetched from its
                // cookie-authenticated dashboard API via the shared session resolution.
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    forceRefresh: forceRefresh,
                    historyDays: historyDays,
                    cursorCookieHeaderOverride: Self.cursorCostHeaderOverride(provider, settings: cursorCookieSettings),
                    refreshPricingInBackground: false,
                    includePiSessions: Self.costIncludePiSessions(
                        provider: provider,
                        groupBy: groupBy,
                        format: format,
                        includePiSessions: includePiSessions))
                switch format {
                case .text:
                    sections.append(Self.renderCostText(
                        provider: provider,
                        snapshot: snapshot,
                        groupBy: groupBy,
                        useColor: useColor,
                        calendar: bucketCalendar,
                        includeBreakdown: includeBreakdown))
                case .json:
                    payload.append(Self.makeCostPayload(
                        provider: provider,
                        snapshot: snapshot,
                        error: nil,
                        calendar: bucketCalendar))
                }
            } catch {
                exitCode = Self.mapError(error)
                if format == .json {
                    payload.append(Self.makeCostPayload(provider: provider, snapshot: nil, error: error))
                } else if !output.jsonOnly {
                    Self.writeStderr("Error: \(error.localizedDescription)\n")
                }
            }
        }

        if format == .json,
           let openCodex = Self.loadOpenCodexCostPayload(
               historyDays: historyDays,
               calendar: bucketCalendar)
        {
            payload.append(openCodex)
        }

        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
        case .json:
            if !payload.isEmpty {
                Self.printJSON(payload, pretty: output.pretty)
            }
        }

        Self.exit(code: exitCode, output: output, kind: exitCode == .success ? .runtime : .provider)
    }

    enum CostGroupBy: String {
        case none
        case project
        case session

        /// Groupings that depend on Codex-local session data and only apply to text output.
        var requiresCodexLocalSessions: Bool {
            switch self {
            case .none: false
            case .project, .session: true
            }
        }
    }

    static func renderCostText(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        groupBy: CostGroupBy = .none,
        useColor: Bool,
        calendar: Calendar = .current,
        includeBreakdown: Bool = false) -> String
    {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        // Provider-specific by design: Antigravity exposes token history, not priced estimates.
        if provider == .antigravity {
            return Self.renderLocalTokenHistoryText(name: name, snapshot: snapshot, useColor: useColor)
        }
        // Provider-specific by design: Codex cost is explicitly an API-equivalent local-session estimate.
        let title = provider == .codex
            ? "\(name) API-equivalent estimate (not billed)"
            : "\(name) Cost (API-rate estimate)"
        let header = Self.costHeaderLine(title, useColor: useColor)
        if groupBy == .project, provider == .codex {
            return Self.renderProjectCostText(header: header, snapshot: snapshot)
        }
        if groupBy == .session, provider == .codex {
            return Self.renderSessionCostText(header: header, snapshot: snapshot)
        }

        let todayCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let todayTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let todayLine = todayTokens.map { "Today: \(todayCost) · \($0) tokens" } ?? "Today: \(todayCost)"

        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthTokens = snapshot.last30DaysTokens.map { UsageFormatter.tokenCountString($0) }
        let historyLabel = snapshot.historyLabel
            ?? (snapshot.historyDays == 1 ? "Today" : "Last \(snapshot.historyDays) days")
        let monthLine = monthTokens.map {
            "\(historyLabel): \(monthCost) · \($0) tokens"
        } ?? "\(historyLabel): \(monthCost)"

        // Plan-metered spend over the same window (what Cursor actually deducts), shown
        // alongside the API-rate estimate. Only providers like Cursor report it.
        let meteredLine: String? = snapshot.meteredCostUSD.map {
            let amount = UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
            return "Cursor-metered: \(amount) (\(historyLabel.lowercased()))"
        }

        let hintLine = Self.costEstimateHint(provider: provider)
        var lines: [String?] = [header, todayLine, monthLine, meteredLine]
        // Provider-specific by design: only Claude local history currently guarantees model attribution.
        if includeBreakdown, provider == .claude, !snapshot.daily.isEmpty {
            lines.append(contentsOf: Self.claudeTokenDetailLines(
                snapshot: snapshot,
                calendar: calendar,
                useColor: useColor))
        }
        lines.append(hintLine)
        return lines.compactMap(\.self).joined(separator: "\n")
    }

    // MARK: - Tokscale-inspired Claude token detail (daily + model breakdown)

    private static func claudeTokenDetailLines(
        snapshot: CostUsageTokenSnapshot,
        calendar: Calendar,
        useColor: Bool) -> [String]
    {
        // Single shared selection: daily and top-model sections describe the same window.
        let selection = Self.claudeRecentEntries(snapshot: snapshot, calendar: calendar)
        guard !selection.entries.isEmpty else { return [] }
        var out: [String] = []
        out.append(contentsOf: Self.claudeDailyLines(
            entries: selection.entries,
            snapshot: snapshot,
            recorded: selection.recorded,
            useColor: useColor))
        out.append(contentsOf: Self.claudeTopModelsLines(
            entries: selection.entries,
            snapshot: snapshot,
            useColor: useColor))
        return out
    }

    private static func claudeRecentEntries(
        snapshot: CostUsageTokenSnapshot,
        calendar: Calendar) -> (entries: [CostUsageDailyReport.Entry], recorded: Bool)
    {
        guard !snapshot.daily.isEmpty else { return ([], false) }
        let today = calendar.startOfDay(for: snapshot.updatedAt)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let intervalDays = min(7, max(1, snapshot.historyDays))
        let recentDayKeys = (0..<intervalDays).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return formatter.string(from: day)
        }
        let recent = snapshot.daily.filter { recentDayKeys.contains($0.date) }
            .sorted { $0.date > $1.date }
        if !recent.isEmpty {
            return (Array(recent.prefix(intervalDays)), false)
        }
        // Stale snapshot: fall back to the latest recorded days, capped at the
        // requested interval and labeled as recorded (never as calendar days).
        let recorded = snapshot.daily.sorted { $0.date > $1.date }.prefix(intervalDays)
        return (Array(recorded), true)
    }

    private static func claudeDailyLines(
        entries: [CostUsageDailyReport.Entry],
        snapshot: CostUsageTokenSnapshot,
        recorded: Bool,
        useColor: Bool) -> [String]
    {
        let intervalDays = min(7, max(1, snapshot.historyDays))
        let title = recorded
            ? "Daily breakdown (last \(entries.count) recorded day\(entries.count == 1 ? "" : "s")):"
            : "Daily breakdown (last \(intervalDays) calendar day\(intervalDays == 1 ? "" : "s")):"
        var out: [String] = ["", useColor ? "\u{001B}[1m\(title)\u{001B}[0m" : title]
        for entry in entries.reversed() {
            // A priced subtotal beside an unpriced model row is not the exact day cost.
            let hasUnpricedUsage = entry.modelBreakdowns?.contains {
                $0.costUSD == nil && ($0.totalTokens ?? 0) > 0
            } ?? false
            let cost = (hasUnpricedUsage ? nil : entry.costUSD)
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) }
                ?? "\u{2014}"
            let total = entry.totalTokens
                .map { UsageFormatter.tokenCountString($0) } ?? "\u{2014}"
            var parts: [String] = []
            if let v = entry.inputTokens { parts.append("in \(UsageFormatter.tokenCountString(v))") }
            if let v = entry.outputTokens { parts.append("out \(UsageFormatter.tokenCountString(v))") }
            if let v = entry.cacheReadTokens, v > 0 {
                parts.append("cacheRead \(UsageFormatter.tokenCountString(v))")
            }
            if let v = entry.cacheCreationTokens, v > 0 {
                parts.append("cacheCreate \(UsageFormatter.tokenCountString(v))")
            }
            let mix = parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
            let models = entry.modelsUsed?.isEmpty == false
                ? " \u{00B7} " + entry.modelsUsed!.prefix(2).joined(separator: ", ")
                + (entry.modelsUsed!.count > 2 ? " +\(entry.modelsUsed!.count - 2)" : "")
                : ""
            out.append("\(entry.date): \(cost) \u{00B7} \(total) tokens\(mix)\(models)")
        }
        return out
    }

    private static func claudeTopModelsLines(
        entries: [CostUsageDailyReport.Entry],
        snapshot: CostUsageTokenSnapshot,
        useColor: Bool) -> [String]
    {
        var hasUnattributedDay = false
        var modelAgg: [String: (cost: Double?, tokens: Int?, days: Set<String>)] = [:]
        for entry in entries {
            guard let breakdowns = entry.modelBreakdowns, !breakdowns.isEmpty else {
                let hasUsage = (entry.costUSD ?? 0) != 0 || (entry.totalTokens ?? 0) > 0
                if hasUsage { hasUnattributedDay = true }
                continue
            }
            for breakdown in breakdowns {
                var cur = modelAgg[breakdown.modelName] ?? (cost: 0, tokens: 0, days: Set<String>())
                // Once unknown (nil), later additions must not resurrect a partial sum.
                if cur.cost != nil {
                    if let c = breakdown.costUSD {
                        cur.cost = cur.cost! + c
                    } else {
                        cur.cost = nil
                    }
                }
                if cur.tokens != nil {
                    if let t = breakdown.totalTokens {
                        let (result, overflow) = cur.tokens!.addingReportingOverflow(t)
                        cur.tokens = overflow ? nil : result
                    } else {
                        cur.tokens = nil
                    }
                }
                cur.days.insert(entry.date)
                modelAgg[breakdown.modelName] = cur
            }
        }
        guard !modelAgg.isEmpty else { return [] }
        let isPartial = !snapshot.historyCoverageIsEstablished || hasUnattributedDay
            || modelAgg.values.contains { $0.cost == nil || $0.tokens == nil }
        let sorted = modelAgg.sorted { lhs, rhs in
            let lCost = lhs.value.cost ?? -1
            let rCost = rhs.value.cost ?? -1
            if lCost != rCost { return lCost > rCost }
            let lTokens = lhs.value.tokens ?? -1
            let rTokens = rhs.value.tokens ?? -1
            if lTokens != rTokens { return lTokens > rTokens }
            return lhs.key < rhs.key
        }
        var out = [""]
        let baseLabel = snapshot.historyLabel ?? "Last \(snapshot.historyDays) days"
        let title = isPartial
            ? "Top models (\(baseLabel) \u{2014} partial):"
            : "Top models (\(baseLabel)):"
        out.append(useColor ? "\u{001B}[1m\(title)\u{001B}[0m" : title)
        for (idx, item) in sorted.prefix(5).enumerated() {
            let costStr = item.value.cost
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) }
                ?? "\u{2014}"
            let tokensStr = item.value.tokens
                .map { UsageFormatter.tokenCountString($0) } ?? "\u{2014}"
            let days = item.value.days.count
            let display = UsageFormatter.modelDisplayName(item.key)
            let dayLabel = days == 1 ? "day" : "days"
            out.append("\(idx + 1). \(display) \u{2014} \(costStr) \u{00B7} \(tokensStr) tokens (\(days) \(dayLabel))")
        }
        if isPartial {
            out.append("Note: Ranking is partial (incomplete history or unattributed cost/tokens).")
        }
        return out
    }

    private static func renderLocalTokenHistoryText(
        name: String,
        snapshot: CostUsageTokenSnapshot,
        useColor: Bool) -> String
    {
        let header = Self.costHeaderLine("\(name) Token History", useColor: useColor)
        let hint = "Local token history · dollar costs unavailable"
        guard snapshot.historyCoverageIsEstablished else {
            return [header, "Local token history is unavailable or incomplete.", hint].joined(separator: "\n")
        }
        let today = snapshot.sessionTokens.map { "\(UsageFormatter.tokenCountString($0)) tokens" } ?? "—"
        let total = snapshot.last30DaysTokens.map { "\(UsageFormatter.tokenCountString($0)) tokens" } ?? "—"
        let historyLabel = snapshot.historyLabel
            ?? (snapshot.historyDays == 1 ? "Today" : "Last \(snapshot.historyDays) days")
        let lines: [String?] = [
            header,
            "Today: \(today)",
            snapshot.historyDays == 1 ? nil : "\(historyLabel): \(total)",
            snapshot.daily.isEmpty ? "No token usage found in the selected period." : nil,
            hint,
        ]
        return lines.compactMap(\.self).joined(separator: "\n")
    }

    private static func renderProjectCostText(header: String, snapshot: CostUsageTokenSnapshot) -> String {
        let historyLabel = snapshot.historyLabel
            ?? (snapshot.historyDays == 1 ? "Today" : "Last \(snapshot.historyDays) days")
        var lines = [header, "Projects (\(historyLabel)):"]
        guard !snapshot.projects.isEmpty else {
            lines.append("—")
            lines.append(Self.costEstimateHint(provider: .codex))
            return lines.joined(separator: "\n")
        }
        for project in snapshot.projects {
            let cost = project.totalCostUSD
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
            let tokens = project.totalTokens.map { UsageFormatter.tokenCountString($0) }
            let summary = tokens.map { "\(cost) · \($0) tokens" } ?? cost
            lines.append("\(project.name): \(summary)")
            if let path = project.path {
                lines.append("  \(path)")
            }
            for source in project.sources {
                let sourceCost = source.totalCostUSD
                    .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
                let sourceTokens = source.totalTokens.map { UsageFormatter.tokenCountString($0) }
                let sourceSummary = sourceTokens.map { "\(sourceCost) · \($0) tokens" } ?? sourceCost
                lines.append("  - \(source.name): \(sourceSummary)")
                if let path = source.path {
                    lines.append("    \(path)")
                }
            }
        }
        lines.append(Self.costEstimateHint(provider: .codex))
        return lines.joined(separator: "\n")
    }

    private static func renderSessionCostText(header: String, snapshot: CostUsageTokenSnapshot) -> String {
        let historyLabel = snapshot.historyLabel
            ?? (snapshot.historyDays == 1 ? "Today" : "Last \(snapshot.historyDays) days")
        var lines = [header, "Conversations (\(historyLabel)):"]
        let historyIncomplete = snapshot.historyCoverageIsEstablished == false
        if historyIncomplete {
            lines.append("Conversation history is incomplete while the local scan catches up.")
        }
        guard !snapshot.sessions.isEmpty else {
            if !historyIncomplete {
                lines.append("—")
            }
            // Provider-specific by design: session output uses Codex's local estimate hint.
            lines.append(Self.costEstimateHint(provider: .codex))
            return lines.joined(separator: "\n")
        }
        for session in snapshot.sessions {
            let cost = session.costUSD
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
            var summary = [cost]
            if let tokens = session.totalTokens {
                summary.append("\(UsageFormatter.tokenCountString(tokens)) tokens")
            }
            if let requests = session.requestCount {
                summary.append("\(requests) requests")
            }
            lines.append("Session \(Self.shortSessionID(session.sessionID)): \(summary.joined(separator: " · "))")
            let modelLabel = Self.sessionModelLabel(session.modelBreakdowns.map(\.modelName))
            lines.append("\(modelLabel) · \(Self.sessionTimestampString(session.lastActivity))")
        }
        // Provider-specific by design: session output uses Codex's local estimate hint.
        lines.append(Self.costEstimateHint(provider: .codex))
        return lines.joined(separator: "\n")
    }

    /// Privacy-conscious shortened session identifier, matching the macOS cost-history UI convention.
    static func shortSessionID(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        return "\(trimmed.prefix(4))...\(trimmed.suffix(8))"
    }

    static func sessionModelLabel(_ models: [String]) -> String {
        let labels = models.map(UsageFormatter.modelDisplayName)
        return if labels.isEmpty {
            "Unknown model"
        } else if labels.count == 1 {
            labels[0]
        } else {
            "\(labels[0]) +\(labels.count - 1) model\(labels.count > 2 ? "s" : "")"
        }
    }

    private static func sessionTimestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    private static func costEstimateHint(provider: UsageProvider) -> String {
        provider == .codex
            ? "Not a subscription bill or plan value · local usage × public API prices"
            : UsageFormatter.costEstimateHint(provider: provider)
    }

    private static func costHeaderLine(_ header: String, useColor: Bool) -> String {
        guard useColor else { return header }
        return "\u{001B}[1;36m\(header)\u{001B}[0m"
    }

    static func costProviders(from selection: ProviderSelection) -> [UsageProvider] {
        selection.asList.filter { Self.costSupportedProviders.contains($0) }
    }

    /// Providers participating in a cost run: text-mode project/session grouping is Codex-only,
    /// while JSON output always keeps every requested provider.
    static func costProviders(
        _ providers: [UsageProvider],
        groupBy: CostGroupBy,
        format: OutputFormat) -> [UsageProvider]
    {
        // Provider-specific by design: text grouping relies on Codex local indexes while JSON preserves all providers.
        providers.filter { !groupBy.requiresCodexLocalSessions || $0 == .codex || format == .json }
    }

    /// Session text reports need native Codex rows, so keep Pi/OMP aggregate merging out of that path.
    static func costIncludePiSessions(
        provider: UsageProvider,
        groupBy: CostGroupBy,
        format: OutputFormat,
        includePiSessions: Bool) -> Bool
    {
        // Provider-specific by design: only Codex local session text bypasses Pi/OMP merging.
        guard provider == .codex, groupBy == .session, format == .text else { return includePiSessions }
        return false
    }

    static func sessionGroupingPiOmissionWarning(
        provider: UsageProvider,
        groupBy: CostGroupBy,
        format: OutputFormat,
        includePiSessions: Bool) -> String?
    {
        // Provider-specific by design: only Codex local session text warns about omitted mirrors.
        guard provider == .codex,
              groupBy == .session,
              format == .text,
              includePiSessions
        else { return nil }
        return "Session grouping shows native Codex conversations only; Pi/OMP usage is omitted from this view. "
            + "Use the default cost view for merged totals."
    }

    /// Provider-specific by design: only Codex JSONL sessions carry the local project/session indexes,
    /// so text-mode grouping skips other providers with a concise stderr notice.
    static func warnSkippedGroupingProviders(
        groupBy: CostGroupBy,
        providers: [UsageProvider],
        jsonOnly: Bool)
    {
        guard !jsonOnly else { return }
        let unsupported = providers.filter { $0 != .codex }
        guard !unsupported.isEmpty else { return }
        let names = unsupported
            .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
            .sorted()
            .joined(separator: ", ")
        switch groupBy {
        case .project:
            Self.writeStderr("Skipping project grouping for providers without Codex project data: \(names)\n")
        case .session:
            Self.writeStderr("Skipping session grouping for providers without Codex session data: \(names)\n")
        case .none:
            break
        }
    }

    static func makeCostPayload(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot?,
        error: Error?,
        calendar: Calendar = .current) -> CostPayload
    {
        let daily = snapshot?.daily.map(Self.costDailyPayload(from:)) ?? []
        let summary = snapshot.map { $0.summary(forLastDays: $0.historyDays, calendar: calendar) }
        let projects = provider == .codex
            ? snapshot?.projects.map { project in
                CostProjectPayload(
                    name: project.name,
                    path: project.path,
                    totalTokens: project.totalTokens,
                    totalCostUSD: project.totalCostUSD,
                    daily: project.daily.map(Self.costDailyPayload(from:)),
                    modelBreakdowns: project.modelBreakdowns?.map(Self.costModelBreakdownPayload(from:)),
                    sources: project.sources.map { source in
                        CostProjectSourcePayload(
                            name: source.name,
                            path: source.path,
                            totalTokens: source.totalTokens,
                            totalCostUSD: source.totalCostUSD,
                            daily: source.daily.map(Self.costDailyPayload(from:)),
                            modelBreakdowns: source.modelBreakdowns?.map(Self.costModelBreakdownPayload(from:)))
                    })
            } ?? []
            : []

        return CostPayload(
            provider: provider.rawValue,
            // Provider-specific by design: Cursor cost comes from its authenticated dashboard, not local logs.
            source: provider == .cursor ? "web" : "local",
            updatedAt: snapshot?.updatedAt ?? (error == nil ? nil : Date()),
            currencyCode: snapshot?.currencyCode,
            sessionTokens: snapshot?.sessionTokens,
            sessionCostUSD: snapshot?.sessionCostUSD,
            historyDays: snapshot?.historyDays,
            historyCoverageIsEstablished: snapshot?.historyCoverageIsEstablished,
            last30DaysTokens: snapshot?.last30DaysTokens,
            last30DaysCostUSD: snapshot?.last30DaysCostUSD,
            meteredCostUSD: snapshot?.meteredCostUSD,
            daily: daily,
            projects: projects,
            totals: snapshot.flatMap(Self.costTotals(from:)),
            provenance: summary?.provenance.rawValue,
            coverage: summary?.coverage,
            error: error.map { Self.makeErrorPayload($0) })
    }

    static func makeOpenCodexCostPayload(
        snapshot: CostUsageTokenSnapshot,
        calendar: Calendar = .current) -> CostPayload
    {
        let summary = snapshot.summary(forLastDays: snapshot.historyDays, calendar: calendar)
        return CostPayload(
            provider: OpenCodexUsageLog.sourceID,
            source: "opencodex",
            updatedAt: snapshot.updatedAt,
            currencyCode: snapshot.currencyCode,
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: snapshot.sessionCostUSD,
            historyDays: snapshot.historyDays,
            historyCoverageIsEstablished: snapshot.historyCoverageIsEstablished,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            meteredCostUSD: nil,
            daily: snapshot.daily.map(self.costDailyPayload(from:)),
            projects: [],
            totals: self.costTotals(from: snapshot),
            provenance: CostProvenance.listPriceEstimate.rawValue,
            coverage: summary.coverage,
            error: nil)
    }

    private static func loadOpenCodexCostPayload(
        historyDays: Int,
        calendar: Calendar,
        now: Date = Date()) -> CostPayload?
    {
        guard boolFromAppDefaults("openCodexUsageLogsEnabled") == true else { return nil }
        let environment = ProcessInfo.processInfo.environment
        guard let logURL = OpenCodexUsageLog.usageLogURL(environment: environment) else { return nil }
        let store = OpenCodexUsageStore(cacheRoot: OpenCodexUsageLog.cacheRoot())
        guard let snapshot = try? store.loadSnapshot(
            logURL: logURL,
            now: now,
            historyDays: historyDays,
            calendar: calendar)
        else { return nil }
        return self.makeOpenCodexCostPayload(snapshot: snapshot, calendar: calendar)
    }

    private static func costDailyPayload(from entry: CostUsageDailyReport.Entry) -> CostDailyEntryPayload {
        CostDailyEntryPayload(
            date: entry.date,
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            reasoningTokens: entry.reasoningTokens,
            totalTokens: entry.totalTokens,
            costUSD: entry.costUSD,
            modelsUsed: entry.modelsUsed,
            modelBreakdowns: entry.modelBreakdowns?.map(self.costModelBreakdownPayload(from:)))
    }

    private static func costModelBreakdownPayload(
        from breakdown: CostUsageDailyReport.ModelBreakdown) -> CostModelBreakdownPayload
    {
        CostModelBreakdownPayload(
            modelName: breakdown.modelName,
            costUSD: breakdown.costUSD,
            totalTokens: breakdown.totalTokens)
    }

    private static func costTotals(from snapshot: CostUsageTokenSnapshot) -> CostTotalsPayload? {
        let entries = snapshot.daily
        guard !entries.isEmpty else {
            guard snapshot.last30DaysTokens != nil || snapshot.last30DaysCostUSD != nil else { return nil }
            return CostTotalsPayload(
                totalInputTokens: nil,
                totalOutputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: snapshot.last30DaysTokens,
                totalCostUSD: snapshot.last30DaysCostUSD)
        }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0
        var totalReasoning = 0
        var totalTokens = 0
        var totalCost = 0.0
        var sawInput = false
        var sawOutput = false
        var sawCacheRead = false
        var sawCacheCreation = false
        var sawReasoning = false
        var sawTokens = false
        var sawCost = false
        var overflowInput = false
        var overflowOutput = false
        var overflowCacheRead = false
        var overflowCacheCreation = false
        var overflowReasoning = false
        var overflowTokens = false

        for entry in entries {
            if let input = entry.inputTokens {
                let (res, of) = totalInput.addingReportingOverflow(input)
                if of { overflowInput = true } else { totalInput = res }
                sawInput = true
            }
            if let output = entry.outputTokens {
                let (res, of) = totalOutput.addingReportingOverflow(output)
                if of { overflowOutput = true } else { totalOutput = res }
                sawOutput = true
            }
            if let cacheRead = entry.cacheReadTokens {
                let (res, of) = totalCacheRead.addingReportingOverflow(cacheRead)
                if of { overflowCacheRead = true } else { totalCacheRead = res }
                sawCacheRead = true
            }
            if let cacheCreation = entry.cacheCreationTokens {
                let (res, of) = totalCacheCreation.addingReportingOverflow(cacheCreation)
                if of { overflowCacheCreation = true } else { totalCacheCreation = res }
                sawCacheCreation = true
            }
            if let reasoning = entry.reasoningTokens {
                let (res, of) = totalReasoning.addingReportingOverflow(reasoning)
                if of { overflowReasoning = true } else { totalReasoning = res }
                sawReasoning = true
            }
            if let tokens = entry.totalTokens {
                let (res, of) = totalTokens.addingReportingOverflow(tokens)
                if of { overflowTokens = true } else { totalTokens = res }
                sawTokens = true
            }
            if let cost = entry.costUSD {
                totalCost += cost
                sawCost = true
            }
        }

        let summary = snapshot.summary(forLastDays: snapshot.historyDays)
        return CostTotalsPayload(
            totalInputTokens: (sawInput && !overflowInput) ? totalInput : nil,
            totalOutputTokens: (sawOutput && !overflowOutput) ? totalOutput : nil,
            cacheReadTokens: (sawCacheRead && !overflowCacheRead) ? totalCacheRead : nil,
            cacheCreationTokens: (sawCacheCreation && !overflowCacheCreation) ? totalCacheCreation : nil,
            reasoningTokens: (sawReasoning && !overflowReasoning) ? totalReasoning : nil,
            totalTokens: (sawTokens && !overflowTokens) ? totalTokens : snapshot.last30DaysTokens,
            totalCostUSD: sawCost ? totalCost : snapshot.last30DaysCostUSD,
            provenance: summary.provenance.rawValue,
            coverage: summary.coverage)
    }

    private static func decodeCostHistoryDays(from values: ParsedValues) -> Int {
        guard let raw = values.options["days"]?.last,
              let parsed = Int(raw)
        else { return 30 }
        return max(1, min(365, parsed))
    }

    static func decodeCostIncludePiSessions(from values: ParsedValues) -> Bool {
        !values.flags.contains("providerNativeOnly")
    }

    static func decodeCostGroupBy(from values: ParsedValues) -> CostGroupBy {
        guard let raw = values.options["groupBy"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return .none }
        return CostGroupBy(rawValue: raw.lowercased()) ?? .none
    }

    /// Human-readable list of providers that support a cost report, used by both `cost` and serve.
    static func costSupportedProviderNames() -> String {
        self.costSupportedProviders
            .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
            .sorted()
            .joined(separator: ", ")
    }

    /// Resolve the configured Cursor cookie settings (source + manual header) the same way the CLI
    /// usage path does, so Cursor cost honors Off/Manual instead of always auto-resolving a session.
    /// Shared by `cost`, the serve `/cost` route, and dashboard snapshot collection.
    static func cursorCookieSettings(
        config: CodexBarConfig,
        providers: [UsageProvider]) throws -> ProviderSettingsSnapshot.CursorProviderSettings?
    {
        // Provider-specific by design: Cursor cost fetches must resolve its selected dashboard-cookie account.
        guard providers.contains(.cursor) else { return nil }
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let context = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try context.resolvedAccounts(for: .cursor).first
        return context.settingsSnapshot(for: .cursor, account: account)?.cursor
    }

    /// Return the actionable error for a Cursor cost fetch disabled by cookie-source policy.
    static func cursorCostAvailabilityError(
        _ provider: UsageProvider,
        settings: ProviderSettingsSnapshot.CursorProviderSettings?,
        resolutionError: Error? = nil) -> Error?
    {
        guard provider == .cursor else { return nil }
        if let resolutionError {
            return resolutionError
        }
        guard let settings else { return nil }
        switch settings.cookieSource {
        case .off:
            return CursorCostAvailabilityError.cookieSourceOff
        case .manual where CookieHeaderNormalizer.normalize(settings.manualCookieHeader) == nil:
            return CursorCostAvailabilityError.manualCookieMissing
        default:
            return nil
        }
    }

    /// Manual cookie header to forward for a Cursor cost fetch, or nil for auto/non-cursor sources.
    static func cursorCostHeaderOverride(
        _ provider: UsageProvider,
        settings: ProviderSettingsSnapshot.CursorProviderSettings?) -> String?
    {
        guard provider == .cursor, settings?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(settings?.manualCookieHeader)
    }
}

enum CursorCostAvailabilityError: LocalizedError {
    case cookieSourceOff
    case manualCookieMissing

    var errorDescription: String? {
        switch self {
        case .cookieSourceOff:
            "Cursor cost is unavailable because the Cursor cookie source is set to Off."
        case .manualCookieMissing:
            "Cursor cost requires a non-empty Manual cookie header."
        }
    }
}

struct CostOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(
        name: .long("provider"),
        help: ProviderHelp.optionHelp)
    var provider: ProviderSelection?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("no-color"), help: "Disable ANSI colors in text output")
    var noColor: Bool = false

    @Flag(name: .long("refresh"), help: "Force refresh by ignoring cached scans")
    var refresh: Bool = false

    @Flag(name: .long("breakdown"), help: "Show daily and model breakdowns in Claude text output")
    var breakdown: Bool = false

    @Flag(
        name: .long("provider-native-only"),
        help: "Experimental: exclude pi and OMP session mirrors from Claude/Codex cost history")
    var providerNativeOnly: Bool = false

    @Option(name: .long("days"), help: "Cost history window in days (1...365)")
    var days: Int?

    @Option(name: .long("group-by"), help: "Group text output by: project | session")
    var groupBy: String?
}

struct CostPayload: Encodable, Sendable {
    let provider: String
    let source: String
    let updatedAt: Date?
    let currencyCode: String?
    let sessionTokens: Int?
    let sessionCostUSD: Double?
    let historyDays: Int?
    let historyCoverageIsEstablished: Bool?
    let last30DaysTokens: Int?
    let last30DaysCostUSD: Double?
    let meteredCostUSD: Double?
    let daily: [CostDailyEntryPayload]
    let projects: [CostProjectPayload]
    let totals: CostTotalsPayload?
    let provenance: String?
    let coverage: CostUsageCoverageCounts?
    let error: ProviderErrorPayload?

    init(
        provider: String,
        source: String,
        updatedAt: Date?,
        currencyCode: String? = nil,
        sessionTokens: Int?,
        sessionCostUSD: Double?,
        historyDays: Int?,
        historyCoverageIsEstablished: Bool? = nil,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?,
        meteredCostUSD: Double? = nil,
        daily: [CostDailyEntryPayload],
        projects: [CostProjectPayload] = [],
        totals: CostTotalsPayload?,
        provenance: String? = nil,
        coverage: CostUsageCoverageCounts? = nil,
        error: ProviderErrorPayload?)
    {
        self.provider = provider
        self.source = source
        self.updatedAt = updatedAt
        self.currencyCode = currencyCode
        self.sessionTokens = sessionTokens
        self.sessionCostUSD = sessionCostUSD
        self.historyDays = historyDays
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.last30DaysTokens = last30DaysTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.meteredCostUSD = meteredCostUSD
        self.daily = daily
        self.projects = projects
        self.totals = totals
        self.provenance = provenance
        self.coverage = coverage
        self.error = error
    }
}

struct CostDailyEntryPayload: Encodable, Sendable {
    let date: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let costUSD: Double?
    let modelsUsed: [String]?
    let modelBreakdowns: [CostModelBreakdownPayload]?

    private enum CodingKeys: String, CodingKey {
        case date
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case reasoningTokens
        case totalTokens
        case costUSD = "totalCost"
        case modelsUsed
        case modelBreakdowns
    }

    init(
        date: String,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        reasoningTokens: Int? = nil,
        totalTokens: Int?,
        costUSD: Double?,
        modelsUsed: [String]?,
        modelBreakdowns: [CostModelBreakdownPayload]?)
    {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.modelsUsed = modelsUsed
        self.modelBreakdowns = modelBreakdowns
    }
}

struct CostModelBreakdownPayload: Encodable, Sendable {
    let modelName: String
    let costUSD: Double?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case modelName
        case costUSD = "cost"
        case totalTokens
    }
}

struct CostProjectPayload: Encodable, Sendable {
    let name: String
    let path: String?
    let totalTokens: Int?
    let totalCostUSD: Double?
    let daily: [CostDailyEntryPayload]
    let modelBreakdowns: [CostModelBreakdownPayload]?
    let sources: [CostProjectSourcePayload]

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case totalTokens
        case totalCostUSD = "totalCost"
        case daily
        case modelBreakdowns
        case sources
    }

    init(
        name: String,
        path: String?,
        totalTokens: Int?,
        totalCostUSD: Double?,
        daily: [CostDailyEntryPayload],
        modelBreakdowns: [CostModelBreakdownPayload]?,
        sources: [CostProjectSourcePayload] = [])
    {
        self.name = name
        self.path = path
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.daily = daily
        self.modelBreakdowns = modelBreakdowns
        self.sources = sources
    }
}

struct CostProjectSourcePayload: Encodable, Sendable {
    let name: String
    let path: String?
    let totalTokens: Int?
    let totalCostUSD: Double?
    let daily: [CostDailyEntryPayload]
    let modelBreakdowns: [CostModelBreakdownPayload]?

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case totalTokens
        case totalCostUSD = "totalCost"
        case daily
        case modelBreakdowns
    }
}

struct CostTotalsPayload: Encodable, Sendable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let totalCostUSD: Double?
    let provenance: String?
    let coverage: CostUsageCoverageCounts?

    private enum CodingKeys: String, CodingKey {
        case totalInputTokens = "inputTokens"
        case totalOutputTokens = "outputTokens"
        case cacheReadTokens
        case cacheCreationTokens
        case reasoningTokens
        case totalTokens
        case totalCostUSD = "totalCost"
        case provenance
        case coverage
    }

    init(
        totalInputTokens: Int?,
        totalOutputTokens: Int?,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        reasoningTokens: Int? = nil,
        totalTokens: Int?,
        totalCostUSD: Double?,
        provenance: String? = nil,
        coverage: CostUsageCoverageCounts? = nil)
    {
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.provenance = provenance
        self.coverage = coverage
    }
}

// Intentionally empty.
