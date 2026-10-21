import CodexBarCore
import SwiftUI

func spendToolActivityRange(group: SpendDashboardModel.CurrencyGroup) -> Range<Date> {
    let start = group.selectedDay.map { group.calendar.startOfDay(for: $0) } ?? group.chartDomain.lowerBound
    let last = group.selectedDay.map { group.calendar.startOfDay(for: $0) } ?? group.chartDomain.upperBound
    let end = group.calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86400)
    return start..<end
}

struct SpendSessionToolActivityView: View {
    let source: SessionToolActivitySource
    let lastActivity: Date
    let range: Range<Date>
    let timeZone: TimeZone
    let hidePersonalInfo: Bool
    @State private var expanded = false
    @State private var snapshot: SessionToolActivitySnapshot?
    @State private var loading = false
    @State private var error = false
    @State private var revision = 0

    private struct LoadKey: Equatable {
        let source: SessionToolActivitySource
        let activity: Date
        let expanded: Bool
        let revision: Int
    }

    var body: some View {
        DisclosureGroup(isExpanded: self.$expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if self.loading {
                    ProgressView(L("spend_tools_loading")).controlSize(.small)
                }
                if self.error {
                    Text(L("spend_tools_unavailable")).foregroundStyle(.secondary)
                } else if let snapshot = self.snapshot, snapshot.source == self.source {
                    SpendToolActivityContent(
                        snapshot: snapshot,
                        range: self.range,
                        hidePersonalInfo: self.hidePersonalInfo,
                        timeZone: self.timeZone)
                }
                HStack {
                    Text(L("spend_tools_scope")).foregroundStyle(.secondary)
                    Image(systemName: "info.circle").help(L("spend_tools_help"))
                    Spacer()
                    Button { self.revision += 1 } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(self.loading)
                    .help(L("Refresh"))
                    .accessibilityLabel(L("Refresh"))
                }
                .font(.caption2)
            }
            .padding(.top, 8)
        } label: {
            Text(L("spend_tools_title")).font(.caption).foregroundStyle(.secondary)
        }
        .task(id: LoadKey(
            source: self.source, activity: self.lastActivity, expanded: self.expanded, revision: self.revision))
        {
            guard !Task.isCancelled else { return }
            guard self.expanded else {
                self.snapshot = nil
                self.loading = false
                self.error = false
                return
            }
            self.loading = true
            self.error = false
            do {
                let snapshot = try await SessionToolActivityStore.shared.load(source: self.source)
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot
                self.loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = true
                self.loading = false
            }
        }
    }
}

enum SpendToolActivityFilter: String, CaseIterable, Identifiable {
    case all, attention, slow
    var id: Self {
        self
    }

    var label: String {
        switch self {
        case .all: L("spend_tools_filter_all")
        case .attention: L("spend_tools_filter_attention")
        case .slow: L("spend_tools_filter_slow")
        }
    }

    func includes(_ operation: SessionToolOperation) -> Bool {
        switch self {
        case .all: true
        case .attention: operation.needsAttention
        case .slow: operation.isSlow
        }
    }
}

struct SpendToolActivityContent: View {
    let snapshot: SessionToolActivitySnapshot
    let range: Range<Date>?
    let hidePersonalInfo: Bool
    var timeZone: TimeZone = .current
    @State var filter: SpendToolActivityFilter = .all
    @State private var rowLimit = 8

    private var operations: [SessionToolOperation] {
        self.snapshot.operations(in: self.range)
    }

    var body: some View {
        let operations = self.operations
        let visible = operations.filter(self.filter.includes)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                self.metric("spend_tools_operations", value: codexBarLocalizedInteger(operations.count))
                self.metric("spend_tools_attention", value: codexBarLocalizedInteger(
                    operations.filter(\.needsAttention).count))
                self.metric("spend_tools_timed", value: L(
                    "spend_tools_coverage",
                    codexBarLocalizedInteger(operations.filter { $0.durationMilliseconds != nil }.count),
                    codexBarLocalizedInteger(operations.count)))
            }
            if self.snapshot.isPartial {
                Label(L("spend_tools_partial"), systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let longest = operations.filter({ $0.timing == .native }).max(by: {
                ($0.durationMilliseconds ?? -1) < ($1.durationMilliseconds ?? -1)
            }), longest.durationMilliseconds != nil {
                HStack(spacing: 6) {
                    Text(L("spend_tools_longest")).foregroundStyle(.secondary)
                    Text(spendToolOperationName(longest, hidePersonalInfo: self.hidePersonalInfo)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(spendToolDuration(longest)).monospacedDigit()
                }
                .font(.caption)
            }
            HStack(spacing: 4) {
                ForEach(SpendToolActivityFilter.allCases) { filter in
                    Button { self.filter = filter } label: {
                        Text(filter.label)
                            .font(.caption.weight(self.filter == filter ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                self.filter == filter ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("spend_tools_filter") + ": " + filter.label)
                    .accessibilityAddTraits(self.filter == filter ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: self.filter) { _, _ in self.rowLimit = 8 }
            if visible.isEmpty {
                Text(L(operations.isEmpty ? "spend_tools_empty" : "spend_tools_no_matches"))
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visible.prefix(self.rowLimit)) { operation in
                        SpendToolOperationRow(
                            operation: operation,
                            snapshot: self.snapshot,
                            hidePersonalInfo: self.hidePersonalInfo,
                            timeZone: self.timeZone)
                    }
                }
                if visible.count > self.rowLimit {
                    Button(L("spend_tools_more")) { self.rowLimit += 20 }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(key)).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SpendToolOperationRow: View {
    let operation: SessionToolOperation
    let snapshot: SessionToolActivitySnapshot
    let hidePersonalInfo: Bool
    let timeZone: TimeZone
    @State private var expanded = false
    @State private var detailsModel = SpendToolDetailsModel()

    private var detailsKey: SpendToolDetailsKey {
        SpendToolDetailsKey(
            operation: self.operation,
            source: self.snapshot.source,
            modified: self.snapshot.modificationDate,
            size: self.snapshot.fileSize,
            fileNumber: self.snapshot.fileNumber,
            expanded: self.expanded,
            hidden: self.hidePersonalInfo)
    }

    var body: some View {
        DisclosureGroup(isExpanded: self.$expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if self.hidePersonalInfo {
                    Text(L("spend_tools_hidden")).foregroundStyle(.secondary)
                } else if self.detailsModel.failed(for: self.detailsKey) {
                    Text(L("spend_tools_changed")).foregroundStyle(.secondary)
                } else if let details = self.detailsModel.details(for: self.detailsKey) {
                    if let input = details.input { self.detailText("spend_tools_input", value: input) }
                    if let output = details.output {
                        self.detailText(
                            details.outputIsRawRecord ? "spend_tools_raw_preview" : "spend_tools_output",
                            value: output)
                    }
                    if details.input == nil, details.output == nil { Text(L("spend_tools_no_details")) }
                    if details.isTruncated { Text(L("spend_tools_truncated")).foregroundStyle(.secondary) }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.caption).padding(.top, 6)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: self.operation.needsAttention ? "exclamationmark.circle" : "circle.fill")
                    .foregroundStyle(self.operation.needsAttention ? Color.orange : Color.secondary)
                    .font(.caption2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(spendToolOperationName(self.operation, hidePersonalInfo: self.hidePersonalInfo))
                        .fontWeight(.medium).lineLimit(1)
                    if !self.hidePersonalInfo, let preview = self.operation.preview {
                        Text(preview).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(spendToolCompletionText(self.operation.completedAt, timeZone: self.timeZone))
                        Text(spendToolOutcome(self.operation))
                    }
                    .foregroundStyle(.secondary).font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(spendToolDuration(self.operation)).monospacedDigit()
                    if self.operation.timing == .recordedInterval {
                        Text(L("spend_tools_interval")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .task(id: self.detailsKey) {
            await self.detailsModel.load(key: self.detailsKey) {
                try await SessionToolActivityStore.shared.details(
                    operation: self.operation, snapshot: self.snapshot)
            }
        }
    }

    private func detailText(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(key)).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(value).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }
}

func spendToolOperationName(_ operation: SessionToolOperation, hidePersonalInfo: Bool) -> String {
    if !hidePersonalInfo, operation.kind == .mcp || operation.kind == .dynamic || operation.kind == .extensionItem {
        return operation.name
    }
    return switch operation.kind {
    case .command: L("spend_tools_kind_command")
    case .mcp: L("spend_tools_kind_mcp")
    case .dynamic: L("spend_tools_kind_dynamic")
    case .fileChange: L("spend_tools_kind_fileChange")
    case .webSearch: L("spend_tools_kind_webSearch")
    case .image: L("spend_tools_kind_image")
    case .extensionItem: L("spend_tools_kind_extensionItem")
    }
}

func spendToolOutcome(_ operation: SessionToolOperation) -> String {
    if operation.outcome == .nonzeroExit, let code = operation.exitCode {
        return L("spend_tools_exit", codexBarLocalizedInteger(code))
    }
    return switch operation.outcome {
    case .completed: L("spend_tools_outcome_completed")
    case .nonzeroExit: L("spend_tools_outcome_nonzeroExit")
    case .toolError: L("spend_tools_outcome_toolError")
    case .declined: L("spend_tools_outcome_declined")
    case .unknown: L("spend_tools_outcome_unknown")
    }
}

func spendToolCompletionText(_ date: Date, timeZone: TimeZone) -> String {
    date.formatted(Date.FormatStyle(
        date: .numeric,
        time: .shortened,
        locale: codexBarLocalizedLocale(),
        calendar: Calendar(identifier: .gregorian),
        timeZone: timeZone))
}

func spendToolDuration(_ operation: SessionToolOperation) -> String {
    guard let duration = operation.durationMilliseconds else { return "—" }
    if duration < 1000 {
        return L("spend_tools_milliseconds", duration.formatted(
            .number.locale(codexBarLocalizedLocale()).precision(.fractionLength(0...1))))
    }
    return L(
        "spend_performance_seconds",
        (duration / 1000).formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(1))))
}
