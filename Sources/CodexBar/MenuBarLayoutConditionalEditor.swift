import CodexBarCore
import SwiftUI

struct MenuBarLayoutConditionalDraft: Identifiable {
    enum Mode: Hashable {
        case create
        case edit(UUID)
    }

    /// Sheet-presentation identity only, unrelated to `conditional.id`.
    let id: UUID
    let mode: Mode
    var conditional: MenuBarLayoutConditional

    init(mode: Mode, conditional: MenuBarLayoutConditional) {
        self.id = UUID()
        self.mode = mode
        self.conditional = conditional
    }
}

@MainActor
struct MenuBarLayoutConditionalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var conditional: MenuBarLayoutConditional

    let draft: MenuBarLayoutConditionalDraft
    let provider: UsageProvider?
    let existingNames: Set<String>
    let onSave: (MenuBarLayoutConditionalDraft) -> Void

    init(
        draft: MenuBarLayoutConditionalDraft,
        provider: UsageProvider?,
        existingNames: Set<String>,
        onSave: @escaping (MenuBarLayoutConditionalDraft) -> Void)
    {
        self.draft = draft
        self.provider = provider
        self.existingNames = existingNames
        self.onSave = onSave
        self._conditional = State(initialValue: draft.conditional)
    }

    private var trimmedName: String {
        self.conditional.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var reservedNames: Set<String> {
        var names = self.existingNames
        // The entry's own current name is allowed so an edit can be saved unchanged.
        names.remove(self.draft.conditional.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        return names
    }

    private var nameIsValid: Bool {
        !self.trimmedName.isEmpty && !self.reservedNames.contains(self.trimmedName.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("menu_bar_layout_conditional_name"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                TextField(L("menu_bar_layout_conditional_name_placeholder"), text: self.$conditional.name)
                    .textFieldStyle(.roundedBorder)
                if !self.nameIsValid {
                    Text(L("menu_bar_layout_conditional_name_error"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text(L("menu_bar_layout_conditional_if"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(self.conditional.clauses.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    if index > 0 {
                        Picker("", selection: self.combinatorBinding(index)) {
                            Text(L("menu_bar_layout_conditional_and")).tag(MenuBarConditionalCombinator.and)
                            Text(L("menu_bar_layout_conditional_or")).tag(MenuBarConditionalCombinator.or)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    Picker("", selection: self.metricBinding(index)) {
                        ForEach(MenuBarConditionalMetric.allCases, id: \.self) { metric in
                            Text(metric.editorLabel).tag(metric)
                        }
                    }
                    .labelsHidden()

                    Picker("", selection: self.comparisonBinding(index)) {
                        ForEach(MenuBarConditionalComparison.allCases, id: \.self) { comparison in
                            Text(comparison.symbol).tag(comparison)
                        }
                    }
                    .labelsHidden()

                    TextField("", value: self.thresholdBinding(index), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .monospacedDigit()
                    Stepper(value: self.thresholdBinding(index), in: 0...100, step: 1) {
                        EmptyView()
                    }
                    .labelsHidden()
                    Text("%")

                    if self.conditional.clauses.count > 1 {
                        Button {
                            self.conditional.clauses.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(L("menu_bar_layout_conditional_add_condition")) {
                self.conditional.clauses.append(
                    MenuBarConditionalClause(
                        combinator: .and,
                        predicate: MenuBarConditionalPredicate(
                            metric: .automatic,
                            comparison: .greaterThan,
                            threshold: 0)))
            }
            .disabled(self.conditional.clauses.count >= 4)
            .buttonStyle(.link)

            HStack {
                Text(L("menu_bar_layout_conditional_then"))
                self.tokenMenu(selection: self.thenBinding)
            }
            HStack {
                Text(L("menu_bar_layout_conditional_else"))
                self.tokenMenu(selection: self.elseBinding)
            }

            Text(self.conditional.editorSummary(provider: self.provider))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) {
                    self.dismiss()
                }
                Button(L("menu_bar_layout_conditional_save")) {
                    self.onSave(
                        MenuBarLayoutConditionalDraft(
                            mode: self.draft.mode,
                            conditional: self.conditional))
                    self.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!self.nameIsValid)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func combinatorBinding(_ index: Int) -> Binding<MenuBarConditionalCombinator> {
        Binding(
            get: {
                guard self.conditional.clauses.indices.contains(index) else { return .and }
                return self.conditional.clauses[index].combinator ?? .and
            },
            set: {
                guard self.conditional.clauses.indices.contains(index) else { return }
                self.conditional.clauses[index].combinator = $0
            })
    }

    private func metricBinding(_ index: Int) -> Binding<MenuBarConditionalMetric> {
        Binding(
            get: {
                guard self.conditional.clauses.indices.contains(index) else { return .session }
                return self.conditional.clauses[index].predicate.metric
            },
            set: {
                guard self.conditional.clauses.indices.contains(index) else { return }
                self.conditional.clauses[index].predicate.metric = $0
            })
    }

    private func comparisonBinding(_ index: Int) -> Binding<MenuBarConditionalComparison> {
        Binding(
            get: {
                guard self.conditional.clauses.indices.contains(index) else { return .greaterThan }
                return self.conditional.clauses[index].predicate.comparison
            },
            set: {
                guard self.conditional.clauses.indices.contains(index) else { return }
                self.conditional.clauses[index].predicate.comparison = $0
            })
    }

    private func thresholdBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard self.conditional.clauses.indices.contains(index) else { return 0 }
                return self.conditional.clauses[index].predicate.threshold
            },
            set: {
                guard self.conditional.clauses.indices.contains(index) else { return }
                self.conditional.clauses[index].predicate.threshold = min(max($0, 0), 100)
            })
    }

    private var thenBinding: Binding<MenuBarLayoutToken> {
        Binding(
            get: { self.conditional.thenToken },
            set: { self.conditional.thenToken = $0 })
    }

    private var elseBinding: Binding<MenuBarLayoutToken> {
        Binding(
            get: { self.conditional.elseToken },
            set: { self.conditional.elseToken = $0 })
    }

    private func tokenMenu(selection: Binding<MenuBarLayoutToken>) -> some View {
        Menu {
            ForEach(Self.selectableTokens, id: \.self) { token in
                Button {
                    selection.wrappedValue = token
                } label: {
                    Label(
                        token.editorLabel(provider: self.provider),
                        systemImage: token.editorSystemImage)
                }
            }
        } label: {
            MenuBarLayoutChipLabel(
                title: selection.wrappedValue.editorLabel(provider: self.provider),
                systemImage: selection.wrappedValue.editorSystemImage,
                isSelected: false)
        }
    }

    private static let selectableTokens: [MenuBarLayoutToken] = [
        .icon,
        .providerName,
        .accountLabel,
        .percent(window: .session),
        .percent(window: .weekly),
        .percent(window: .scopedWeekly),
        .percent(window: .automatic),
        .usageBar,
        .pace(window: .session),
        .pace(window: .weekly),
        .pace(window: .automatic),
        .resetCountdown,
        .resetAbsolute,
        .runsOut,
        .runsOutCompact,
        .balance,
        .costToday,
        .cost30d,
        .separatorDot,
        .space,
        .hidden,
    ]
}

extension MenuBarLayoutConditional {
    /// The chip label: the required name, falling back to a generic label if somehow empty.
    var displayName: String {
        let trimmed = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("menu_bar_layout_token_conditional") : trimmed
    }

    /// Produces a summary string reflecting the left-fold AND/OR evaluation order. Mixed
    /// combinators parenthesize their accumulator so the reading matches `evaluatesTrue`.
    private func conditionText() -> String {
        guard let first = self.clauses.first else { return "" }
        let mixed = Set(self.clauses.dropFirst().compactMap(\.combinator)).count > 1
        var text = Self.predicateText(first.predicate)
        for clause in self.clauses.dropFirst() {
            let joiner = (clause.combinator ?? .and) == .and
                ? L("menu_bar_layout_conditional_and")
                : L("menu_bar_layout_conditional_or")
            let pred = Self.predicateText(clause.predicate)
            text = mixed ? "(\(text)) \(joiner) \(pred)" : "\(text) \(joiner) \(pred)"
        }
        return text
    }

    private static func predicateText(_ predicate: MenuBarConditionalPredicate) -> String {
        "\(predicate.metric.editorLabel) \(predicate.comparison.symbol) \(Int(predicate.threshold.rounded()))%"
    }

    func editorSummary(provider: UsageProvider?) -> String {
        let condition = self.conditionText()
        return L(
            "menu_bar_layout_conditional_summary",
            condition,
            self.thenToken.editorLabel(provider: provider),
            self.elseToken.editorLabel(provider: provider))
    }

    /// Generates a unique copy name that avoids collisions with existing library entries.
    static func uniqueCopyName(basedOn name: String, existingNames: Set<String>) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? L("menu_bar_layout_token_conditional") : base
        var candidate = L("menu_bar_layout_conditional_copy_name", stem)
        var n = 2
        while existingNames.contains(candidate.lowercased()) {
            candidate = L("menu_bar_layout_conditional_copy_name_numbered", stem, n)
            n += 1
        }
        return candidate
    }
}

extension MenuBarConditionalMetric {
    var editorLabel: String {
        switch self {
        case .session: L("menu_bar_layout_token_session")
        case .weekly: L("menu_bar_layout_token_weekly")
        case .scopedWeekly: L("menu_bar_layout_token_scoped_weekly")
        case .automatic: L("menu_bar_layout_token_auto")
        }
    }
}
