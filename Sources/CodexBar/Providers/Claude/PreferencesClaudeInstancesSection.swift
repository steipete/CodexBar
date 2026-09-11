import CodexBarCore
import SwiftUI

/// Editable copy of one instance; changes reach settings only on Save so typing never triggers refreshes.
struct ClaudeInstanceDraft: Equatable, Identifiable {
    var id: String
    var name: String
    var binaryPath: String
    var configDirectory: String
    var environmentText: String

    init(instance: ClaudeInstanceConfig) {
        self.id = instance.id
        self.name = instance.name
        self.binaryPath = instance.binaryPath ?? ""
        self.configDirectory = instance.configDirectory
        self.environmentText = ClaudeInstanceEnvironment.formatVariables(instance.environment)
    }

    static func new() -> ClaudeInstanceDraft {
        ClaudeInstanceDraft(instance: ClaudeInstanceConfig(name: "", configDirectory: ""))
    }

    var hasValidConfigDirectory: Bool {
        ClaudeInstanceEnvironment.normalizedAbsolutePath(self.configDirectory) != nil
    }

    var hasValidBinaryPath: Bool {
        let trimmed = self.binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || ClaudeInstanceEnvironment.normalizedAbsolutePath(trimmed) != nil
    }

    var canSave: Bool {
        self.hasValidConfigDirectory && self.hasValidBinaryPath
    }

    func makeInstance() -> ClaudeInstanceConfig? {
        guard let configDirectory = ClaudeInstanceEnvironment.normalizedAbsolutePath(self.configDirectory),
              self.hasValidBinaryPath
        else { return nil }
        let variables = ClaudeInstanceEnvironment.sanitizedVariables(
            ClaudeInstanceEnvironment.parseVariables(self.environmentText))
        return ClaudeInstanceConfig(
            id: self.id,
            name: self.name.trimmingCharacters(in: .whitespacesAndNewlines),
            binaryPath: ClaudeInstanceEnvironment.normalizedAbsolutePath(self.binaryPath),
            configDirectory: configDirectory,
            environment: variables.isEmpty ? nil : variables)
    }
}

extension SettingsStore {
    /// Inserts a new instance or replaces the one with the same ID, keeping list order.
    func saveClaudeInstance(_ instance: ClaudeInstanceConfig) {
        var instances = self.claudeInstances
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        } else {
            instances.append(instance)
        }
        self.claudeInstances = instances
    }

    func removeClaudeInstance(id: String) {
        self.claudeInstances = self.claudeInstances.filter { $0.id != id }
    }
}

@MainActor
struct ClaudeInstancesSectionView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var editingDraft: ClaudeInstanceDraft?

    var body: some View {
        Section {
            Toggle(isOn: self.$settings.claudeInstancesEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Show Claude instances"))
                    Text(L("claude_instances_toggle_subtitle"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(Array(self.settings.claudeInstances.enumerated()), id: \.element.id) { index, instance in
                ClaudeInstanceRowView(
                    title: ClaudeInstanceAccountProjection.displayLabel(for: instance, index: index),
                    configDirectory: instance.normalizedConfigDirectory ?? instance.configDirectory,
                    status: self.status(for: instance),
                    onEdit: { self.editingDraft = ClaudeInstanceDraft(instance: instance) },
                    onRemove: { self.settings.removeClaudeInstance(id: instance.id) })
            }

            Button(L("Add Instance")) {
                self.editingDraft = .new()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } header: {
            Text(L("Claude instances"))
        }
        .sheet(item: self.$editingDraft) { draft in
            ClaudeInstanceEditorView(
                draft: draft,
                onSave: { instance in
                    self.settings.saveClaudeInstance(instance)
                    self.editingDraft = nil
                },
                onCancel: { self.editingDraft = nil })
        }
    }

    private func status(for instance: ClaudeInstanceConfig) -> (text: String, isError: Bool)? {
        guard self.settings.claudeInstancesEnabled else { return nil }
        let id = ClaudeInstanceAccountProjection.identity(for: instance)
        guard let account = self.store.claudeInstanceAccountSnapshots.first(where: { $0.id == id }) else {
            return nil
        }
        if let error = account.error {
            return (error, true)
        }
        guard let updatedAt = account.snapshot?.updatedAt else { return nil }
        return (String(format: L("Updated %@"), updatedAt.relativeDescription()), false)
    }
}

private struct ClaudeInstanceRowView: View {
    let title: String
    let configDirectory: String
    let status: (text: String, isError: Bool)?
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.subheadline.weight(.semibold))
                Text(self.configDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status {
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status.isError ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button(L("Edit")) {
                self.onEdit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(L("Remove")) {
                self.onRemove()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct ClaudeInstanceEditorView: View {
    @State var draft: ClaudeInstanceDraft
    let onSave: (ClaudeInstanceConfig) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField(L("Name"), text: self.$draft.name)
                self.field(
                    title: L("Binary path"),
                    text: self.$draft.binaryPath,
                    prompt: "claude",
                    footnote: L("claude_instance_binary_footnote"),
                    isValid: self.draft.hasValidBinaryPath)
                self.field(
                    title: L("CLAUDE_CONFIG_DIR path"),
                    text: self.$draft.configDirectory,
                    prompt: "~/.claude-work",
                    footnote: L("claude_instance_config_dir_footnote"),
                    isValid: self.draft.configDirectory.isEmpty || self.draft.hasValidConfigDirectory)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Environment"))
                    TextEditor(text: self.$draft.environmentText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                    Text(L("claude_instance_environment_footnote"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(L("cancel"), role: .cancel) {
                    self.onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    if let instance = self.draft.makeInstance() {
                        self.onSave(instance)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!self.draft.canSave)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 460)
    }

    private func field(
        title: String,
        text: Binding<String>,
        prompt: String,
        footnote: String,
        isValid: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text, prompt: Text(prompt))
            Text(isValid ? footnote : L("Use an absolute path or a path starting with ~."))
                .font(.footnote)
                .foregroundStyle(isValid ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
