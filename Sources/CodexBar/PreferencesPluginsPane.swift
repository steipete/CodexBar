#if canImport(JavaScriptCore)
import AppKit
import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PluginsPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var results: [UserProviderPluginLoadResult] = []
    @State private var pendingApproval: PendingPluginApproval?
    @State private var pendingDelete: PluginDeleteRequest?
    @State private var operationError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Install…") { self.choosePlugin() }
                    Button("Refresh") { self.refresh() }
                    Spacer()
                    Text(UserProviderPluginLoader.defaultProvidersDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Provider Plugins")
            } footer: {
                Text("Plugins are local JavaScript or TypeScript files. Network and cookie access require approval.")
            }

            if self.results.isEmpty {
                ContentUnavailableView(
                    "No Plugins Installed",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Drop one .js or .ts file into the plugins directory, or choose Install…."))
            }

            ForEach(self.results, id: \.fileURL) { result in
                if let plugin = result.plugin {
                    self.pluginSection(plugin)
                } else {
                    self.invalidPluginSection(result)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { self.refresh() }
        .sheet(item: self.$pendingApproval) { pending in
            PluginApprovalSheet(
                pending: pending,
                onCancel: { self.pendingApproval = nil },
                onApprove: { confirmations, settings in
                    self.completeApproval(pending, confirmations: confirmations, settings: settings)
                })
        }
        .alert(
            "Delete Plugin?",
            isPresented: Binding(
                get: { self.pendingDelete != nil },
                set: {
                    if !$0 {
                        self.pendingDelete = nil
                    }
                }),
            actions: {
                Button("Delete", role: .destructive) { self.completeDelete() }
                Button("Cancel", role: .cancel) { self.pendingDelete = nil }
            },
            message: {
                Text(
                    "This removes the plugin file, transpile cache, approval, saved settings and secrets, and history.")
            })
        .alert(
            "Plugin Error",
            isPresented: Binding(
                get: { self.operationError != nil },
                set: {
                    if !$0 {
                        self.operationError = nil
                    }
                }),
            actions: { Button("OK") { self.operationError = nil } },
            message: { Text(self.operationError ?? "") })
    }

    private func pluginSection(_ plugin: UserProviderPlugin) -> some View {
        let binding = try? plugin.approvalBinding(
            settings: self.settings.pluginConfig(plugin.manifest.id)?.pluginSettings ?? [:])
        let approved = binding.map(self.store.pluginApprovalStore.isApproved) == true
        let status = if !self.settings.isPluginEnabled(plugin.manifest.id) {
            "Disabled"
        } else if approved {
            "Active"
        } else {
            "Needs approval"
        }

        return Section {
            LabeledContent("File") {
                Text(plugin.fileURL.path).textSelection(.enabled)
            }
            LabeledContent("Status", value: status)
            LabeledContent("Origins", value: binding?.origins.joined(separator: ", ") ?? "Configure endpoint settings")
            LabeledContent(
                "Capabilities",
                value: plugin.manifest.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
                    .nilIfEmpty ?? "Network")
            if !plugin.manifest.cookieDomains.isEmpty {
                LabeledContent("Cookie domains", value: plugin.manifest.cookieDomains.sorted().joined(separator: ", "))
            }
            Toggle("Enabled", isOn: self.enabledBinding(plugin.manifest.id))
            ForEach(plugin.manifest.settings, id: \.key) { setting in
                if setting.kind == .secure {
                    SecureField(setting.title, text: self.settingBinding(plugin.manifest.id, setting: setting))
                } else {
                    TextField(setting.title, text: self.settingBinding(plugin.manifest.id, setting: setting))
                }
                if let subtitle = setting.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = self.store.errors[plugin.manifest.id] {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if !approved {
                    Button("Approve…") { self.requestApproval(plugin: plugin, sourceURL: nil) }
                }
                Button("Refresh") {
                    Task { await self.store.refreshUserPlugin(plugin.manifest.id) }
                }
                Spacer()
                Button("Delete…", role: .destructive) {
                    self.pendingDelete = PluginDeleteRequest(fileURL: plugin.fileURL, plugin: plugin)
                }
            }
        } header: {
            Label(plugin.manifest.name, systemImage: "puzzlepiece.extension")
        }
    }

    private func invalidPluginSection(_ result: UserProviderPluginLoadResult) -> some View {
        Section {
            LabeledContent("File") { Text(result.fileURL.path).textSelection(.enabled) }
            LabeledContent("Status", value: "Error")
            Text(result.error ?? "Unknown validation error")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Delete…", role: .destructive) {
                    self.pendingDelete = PluginDeleteRequest(fileURL: result.fileURL, plugin: nil)
                }
            }
        } header: {
            Label(result.fileURL.deletingPathExtension().lastPathComponent, systemImage: "exclamationmark.triangle")
        }
    }

    private func refresh() {
        self.store.refreshUserPluginDiscovery()
        self.results = UserProviderPluginRegistry.allResults
    }

    private func choosePlugin() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["js", "ts"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plugin = try UserProviderPluginLoader().load(fileURL: url)
            if plugin.manifest.id.firstPartyProvider != nil ||
                UserProviderPluginRegistry.plugin(for: plugin.manifest.id) != nil
            {
                throw ProviderPluginError.invalidManifest(
                    "provider id '\(plugin.manifest.id.rawValue)' collides with another provider")
            }
            self.requestApproval(plugin: plugin, sourceURL: url)
        } catch {
            self.operationError = error.localizedDescription
        }
    }

    private func requestApproval(plugin: UserProviderPlugin, sourceURL: URL?) {
        let config = self.settings.pluginConfig(plugin.manifest.id)
        self.pendingApproval = PendingPluginApproval(
            plugin: plugin,
            sourceURL: sourceURL,
            initialSettings: config?.pluginSettings ?? [:])
    }

    private func completeApproval(
        _ pending: PendingPluginApproval,
        confirmations: [String: String],
        settings: [String: String])
    {
        do {
            let binding = try pending.plugin.approvalBinding(settings: settings)
            guard binding.typedConfirmationOrigins.allSatisfy({ confirmations[$0] == $0 }) else { return }
            let plugin: UserProviderPlugin = if let sourceURL = pending.sourceURL {
                try UserProviderPluginLoader().install(fileURL: sourceURL)
            } else {
                pending.plugin
            }
            let installedBinding = try plugin.approvalBinding(settings: settings)
            guard installedBinding == binding else {
                throw ProviderPluginError.load("plugin authority changed during installation; review it again")
            }
            self.settings.updatePluginConfig(instanceID: plugin.manifest.id) {
                $0.enabled = true
                $0.pluginSettings = settings
            }
            try self.store.pluginApprovalStore.record(installedBinding)
            self.pendingApproval = nil
            self.refresh()
            Task { await self.store.refreshUserPlugin(plugin.manifest.id) }
        } catch {
            self.pendingApproval = nil
            self.operationError = error.localizedDescription
        }
    }

    private func completeDelete() {
        guard let request = self.pendingDelete else { return }
        do {
            if let plugin = request.plugin {
                try self.store.deleteUserPlugin(plugin)
            } else if FileManager.default.fileExists(atPath: request.fileURL.path) {
                try FileManager.default.removeItem(at: request.fileURL)
            }
            self.pendingDelete = nil
            self.refresh()
        } catch {
            self.pendingDelete = nil
            self.operationError = error.localizedDescription
        }
    }

    private func enabledBinding(_ instanceID: ProviderInstanceID) -> Binding<Bool> {
        Binding(
            get: { self.settings.isPluginEnabled(instanceID) },
            set: { self.settings.setPluginEnabled(instanceID, enabled: $0) })
    }

    private func settingBinding(
        _ instanceID: ProviderInstanceID,
        setting: ProviderPluginSetting) -> Binding<String>
    {
        Binding(
            get: {
                let config = self.settings.pluginConfig(instanceID)
                return setting.kind == .secure
                    ? config?.pluginSecrets?[setting.key] ?? ""
                    : config?.pluginSettings?[setting.key] ?? ""
            },
            set: { value in
                self.settings.updatePluginConfig(instanceID: instanceID) { config in
                    if setting.kind == .secure {
                        var values = config.pluginSecrets ?? [:]
                        values[setting.key] = value
                        config.pluginSecrets = values
                    } else {
                        var values = config.pluginSettings ?? [:]
                        values[setting.key] = value
                        config.pluginSettings = values
                    }
                }
            })
    }
}

private struct PendingPluginApproval: Identifiable {
    let id = UUID()
    let plugin: UserProviderPlugin
    let sourceURL: URL?
    let initialSettings: [String: String]
}

private struct PluginDeleteRequest {
    let fileURL: URL
    let plugin: UserProviderPlugin?
}

private struct PluginApprovalSheet: View {
    let pending: PendingPluginApproval
    let onCancel: () -> Void
    let onApprove: ([String: String], [String: String]) -> Void
    @State private var confirmations: [String: String] = [:]
    @State private var settings: [String: String]

    init(
        pending: PendingPluginApproval,
        onCancel: @escaping () -> Void,
        onApprove: @escaping ([String: String], [String: String]) -> Void)
    {
        self.pending = pending
        self.onCancel = onCancel
        self.onApprove = onApprove
        self._settings = State(initialValue: pending.initialSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(self.pending.sourceURL == nil ? "Approve Plugin" : "Install and Approve Plugin")
                .font(.title2.bold())
            Text(self.pending.plugin.manifest.name)
            ForEach(self.pending.plugin.manifest.settings.filter { $0.kind == .plain }, id: \.key) { setting in
                TextField(setting.title, text: Binding(
                    get: { self.settings[setting.key] ?? "" },
                    set: { self.settings[setting.key] = $0 }))
            }
            if let binding = self.binding {
                GroupBox("Network authority") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(binding.origins, id: \.self) { Text($0).textSelection(.enabled) }
                        Text("Auth: \(binding.authMode)")
                        Text(
                            "Capabilities: " +
                                (binding.capabilities.joined(separator: ", ").nilIfEmpty ?? "network"))
                        Text("Secrets: \(binding.secretNames.joined(separator: ", ").nilIfEmpty ?? "none")")
                        if !binding.cookieDomains.isEmpty {
                            Text("Cookie domains: \(binding.cookieDomains.joined(separator: ", "))")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(binding.typedConfirmationOrigins, id: \.self) { origin in
                    TextField("Type \(origin) to confirm", text: Binding(
                        get: { self.confirmations[origin] ?? "" },
                        set: { self.confirmations[origin] = $0 }))
                }
            } else {
                Text("Enter every endpoint setting to review the exact network origins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: self.onCancel)
                Button(self.pending.sourceURL == nil ? "Approve" : "Install") {
                    self.onApprove(self.confirmations, self.settings)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!self.canApprove)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var canApprove: Bool {
        guard let binding = self.binding else { return false }
        return binding.typedConfirmationOrigins.allSatisfy { self.confirmations[$0] == $0 }
    }

    private var binding: ProviderPluginApprovalBinding? {
        try? self.pending.plugin.approvalBinding(settings: self.settings)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
#endif
