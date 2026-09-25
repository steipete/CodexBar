import AppKit
import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesTransferSection: View {
    @Bindable var settings: SettingsStore
    @State private var failure: String?
    @State private var editingShortcuts = false

    var body: some View {
        Section {
            HStack {
                Button("Export Preferences…") { self.transfer(importing: false) }
                Button("Import Preferences…") { self.transfer(importing: true) }
            }
            Button("Provider Switcher Shortcuts…") { self.editingShortcuts = true }
        } header: {
            Text("Portable preferences")
        } footer: {
            Text("Save display and notification preferences for your dotfiles. Accounts, credentials, login, " +
                "local paths and consent stay on this Mac.")
        }
        .alert("Preferences could not be transferred", isPresented: Binding(
            get: { self.failure != nil }, set: { if !$0 { self.failure = nil } }))
        {
            Button("OK") { self.failure = nil }
        } message: {
            Text(self.failure ?? "")
        }
        .sheet(isPresented: self.$editingShortcuts) {
                ProviderSwitcherShortcutEditor(settings: self.settings)
            }
    }

    private func transfer(importing: Bool) {
        let panel: NSSavePanel = importing ? NSOpenPanel() : NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "preferences.json"
        if let open = panel as? NSOpenPanel { open.allowsMultipleSelection = false }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if importing {
                try self.settings.importPreferences(PreferencesDocument(data: Data(contentsOf: url)))
            } else {
                try self.settings.exportPreferences().encoded().write(to: url, options: .atomic)
            }
        } catch {
            self.failure = error.localizedDescription
        }
    }
}

struct ProviderSwitcherShortcutEditor: View {
    let settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var shortcuts: [String: String] = [:]
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Provider Switcher Shortcuts").font(.headline)
            Text("These shortcuts work while the provider switcher menu is open. " +
                "Use ctrl, alt, shift and cmd with a letter, digit, left or right; use none to disable an action.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                ForEach(ProviderSwitcherShortcuts.actions, id: \.self) { action in
                    TextField(self.label(action), text: Binding(
                        get: { self.shortcuts[action] ?? "" },
                        set: { self.shortcuts[action] = $0 }))
                }
            }
            Text("Examples: alt+cmd+2, shift+right. Refresh (cmd+r), Settings (cmd+,) and Quit (cmd+q) are reserved.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).accessibilityLabel("Error: \(failure)") }
            HStack {
                Button("Restore Defaults") { self.shortcuts = ProviderSwitcherShortcuts.defaults; self.failure = nil }
                Spacer()
                Button("Cancel") { self.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try self.settings.setProviderSwitcherShortcuts(self.shortcuts)
                        self.dismiss()
                    } catch { self.failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { self.shortcuts = self.settings.providerSwitcherShortcuts }
    }

    private func label(_ action: String) -> String {
        switch action {
        case "previous": "Previous provider"
        case "next": "Next provider"
        default: "Select position \(action.dropFirst(6))"
        }
    }
}
