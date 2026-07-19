import CodexBarCore
import SwiftUI

@MainActor
struct HooksPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.enabledBinding) {
                    SettingsRowLabel(L("hooks_enable_title"), subtitle: L("hooks_enable_subtitle"))
                }
                Label(L("hooks_trust_warning"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("tab_hooks"))
            }

            Section {
                if self.settings.hookRules.isEmpty {
                    Text(L("hooks_empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.settings.hookRules) { rule in
                        HookRuleRow(
                            rule: self.binding(for: rule),
                            onDelete: { self.settings.removeHookRule(id: rule.id) })
                    }
                }

                Button {
                    self.settings.addHookRule(HookRule(event: .quotaReached, executable: ""))
                } label: {
                    Label(L("hooks_add_rule"), systemImage: "plus")
                }
                .disabled(!HookEditorValidation.canAddRule(count: self.settings.hookRules.count))
            } header: {
                Text(L("hooks_rules_header"))
            }
        }
        .formStyle(.grouped)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.hooksEnabled },
            set: { self.settings.setHooksEnabled($0) })
    }

    private func binding(for rule: HookRule) -> Binding<HookRule> {
        Binding(
            get: { self.settings.hookRules.first(where: { $0.id == rule.id }) ?? rule },
            set: { self.settings.updateHookRule($0) })
    }
}

@MainActor
private struct HookRuleRow: View {
    @Binding var rule: HookRule
    let onDelete: () -> Void
    @State private var argumentRows: [ArgumentRow]

    init(rule: Binding<HookRule>, onDelete: @escaping () -> Void) {
        self._rule = rule
        self.onDelete = onDelete
        self._argumentRows = State(initialValue: rule.wrappedValue.arguments.map(ArgumentRow.init(value:)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(L("hooks_rule_enabled"), isOn: self.$rule.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                Picker(L("hooks_event"), selection: self.$rule.event) {
                    ForEach(HookEventType.allCases, id: \.self) { event in
                        Text(event.rawValue).tag(event)
                    }
                }
                .labelsHidden()

                Picker(L("hooks_provider"), selection: self.providerBinding) {
                    Text(L("hooks_any_provider")).tag(String?.none)
                    ForEach(UsageProvider.allCases, id: \.self) { provider in
                        Text(ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)
                            .tag(String?.some(provider.rawValue))
                    }
                }
                .labelsHidden()

                Spacer()

                Button(role: .destructive, action: self.onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("hooks_delete_rule"))
            }

            if self.rule.event == .quotaLow {
                HStack {
                    Text(L("hooks_threshold"))
                        .foregroundStyle(.secondary)
                    TextField(L("hooks_threshold_placeholder"), value: self.thresholdPercentBinding, format: .number)
                        .frame(width: 60)
                    Text(verbatim: "%")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            TextField(L("hooks_executable_placeholder"), text: self.$rule.executable)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("hooks_arguments_placeholder"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        self.argumentRows.append(ArgumentRow(value: ""))
                    } label: {
                        Label(L("hooks_add_argument"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!HookEditorValidation.canAddArgument(count: self.argumentRows.count))
                }

                ForEach(self.$argumentRows) { $argument in
                    HStack {
                        TextField(L("hooks_argument_placeholder"), text: $argument.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button {
                            self.argumentRows.removeAll(where: { $0.id == argument.id })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("hooks_delete_argument"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: self.argumentRows.map(\.value)) { _, arguments in
            if self.rule.arguments != arguments {
                self.rule.arguments = arguments
            }
        }
        .onChange(of: self.rule.arguments) { _, arguments in
            if self.argumentRows.map(\.value) != arguments {
                self.argumentRows = arguments.map(ArgumentRow.init(value:))
            }
        }
    }

    private var providerBinding: Binding<String?> {
        Binding(get: { self.rule.provider }, set: { self.rule.provider = $0 })
    }

    /// Threshold stored as a 0...1 fraction, edited as a 0...100 percentage.
    private var thresholdPercentBinding: Binding<Double?> {
        Binding(
            get: { self.rule.threshold.map { $0 * 100 } },
            set: { self.rule.threshold = HookEditorValidation.thresholdFraction(percent: $0) })
    }

    private struct ArgumentRow: Identifiable {
        let id = UUID()
        var value: String
    }
}

enum HookEditorValidation {
    static func canAddRule(count: Int) -> Bool {
        count < HooksConfig.maximumRuleCount
    }

    static func canAddArgument(count: Int) -> Bool {
        count < HookRule.maximumArgumentCount
    }

    static func thresholdFraction(percent: Double?) -> Double? {
        percent.map { min(max($0, 1), 100) / 100 }
    }
}
