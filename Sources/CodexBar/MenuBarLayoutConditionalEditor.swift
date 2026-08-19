import CodexBarCore
import SwiftUI

struct MenuBarLayoutConditionalDraft: Identifiable {
    enum Mode: Hashable {
        case create
        case editLibrary(Int)
        case editPlaced(MenuBarLayoutPosition)
    }

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
    let onSave: (MenuBarLayoutConditionalDraft) -> Void

    init(
        draft: MenuBarLayoutConditionalDraft,
        provider: UsageProvider?,
        onSave: @escaping (MenuBarLayoutConditionalDraft) -> Void)
    {
        self.draft = draft
        self.provider = provider
        self.onSave = onSave
        self._conditional = State(initialValue: draft.conditional)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func combinatorBinding(_ index: Int) -> Binding<MenuBarConditionalCombinator> {
        Binding(
            get: { self.conditional.clauses[index].combinator ?? .and },
            set: { self.conditional.clauses[index].combinator = $0 })
    }

    private func metricBinding(_ index: Int) -> Binding<MenuBarConditionalMetric> {
        Binding(
            get: { self.conditional.clauses[index].predicate.metric },
            set: { self.conditional.clauses[index].predicate.metric = $0 })
    }

    private func comparisonBinding(_ index: Int) -> Binding<MenuBarConditionalComparison> {
        Binding(
            get: { self.conditional.clauses[index].predicate.comparison },
            set: { self.conditional.clauses[index].predicate.comparison = $0 })
    }

    private func thresholdBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { self.conditional.clauses[index].predicate.threshold },
            set: { self.conditional.clauses[index].predicate.threshold = min(max($0, 0), 100) })
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
    ]
}

extension MenuBarLayoutConditional {
    func editorSummary(provider: UsageProvider?) -> String {
        let condition = self.clauses.enumerated().map { index, clause -> String in
            let predicate = "\(clause.predicate.metric.editorLabel) \(clause.predicate.comparison.symbol) "
                + "\(Int(clause.predicate.threshold.rounded()))%"
            guard index > 0, let combinator = clause.combinator else { return predicate }
            let joiner = combinator == .and
                ? L("menu_bar_layout_conditional_and")
                : L("menu_bar_layout_conditional_or")
            return "\(joiner) \(predicate)"
        }.joined(separator: " ")
        return L(
            "menu_bar_layout_conditional_summary",
            condition,
            self.thenToken.editorLabel(provider: provider),
            self.elseToken.editorLabel(provider: provider))
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
