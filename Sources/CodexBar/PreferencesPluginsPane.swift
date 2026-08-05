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
                LabeledContent {
                    Button(L("Install…")) { self.choosePlugin() }
                } label: {
                    SettingsRowLabel(
                        L("Install plugin"),
                        subtitle: L("Copies a JavaScript or TypeScript file into the plugins directory."))
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        Button(L("Refresh")) { self.refresh() }
                        Button(L("Show in Finder")) { self.revealPluginsDirectory() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Plugins directory"))
                        Text(Self.pluginsDirectoryDisplayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text(L("Provider Plugins"))
            } footer: {
                SettingsSectionFooter(
                    L("Plugins are local JavaScript or TypeScript files. Network and cookie access require approval."))
            }

            if self.results.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L("No Plugins Installed"), systemImage: "puzzlepiece.extension")
                    } description: {
                        Text(L("Drop a .js or .ts file into the plugins directory, or choose Install…"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
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
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
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
            L("Delete Plugin?"),
            isPresented: Binding(
                get: { self.pendingDelete != nil },
                set: {
                    if !$0 {
                        self.pendingDelete = nil
                    }
                }),
            actions: {
                Button(L("Delete"), role: .destructive) { self.completeDelete() }
                Button(L("Cancel"), role: .cancel) { self.pendingDelete = nil }
            },
            message: {
                Text(L(
                    "This removes the plugin file, transpile cache, approval, " +
                        "saved settings and secrets, and history."))
            })
        .alert(
            L("Plugin Error"),
            isPresented: Binding(
                get: { self.operationError != nil },
                set: {
                    if !$0 {
                        self.operationError = nil
                    }
                }),
            actions: { Button(L("OK")) { self.operationError = nil } },
            message: { Text(self.operationError ?? "") })
    }

    private func pluginSection(_ plugin: UserProviderPlugin) -> some View {
        let binding = try? plugin.approvalBinding(
            settings: self.settings.pluginConfig(plugin.manifest.id)?.pluginSettings ?? [:])
        let approved = binding.map(self.store.pluginApprovalStore.isApproved) == true
        let status = if !self.settings.isPluginEnabled(plugin.manifest.id) {
            L("Disabled")
        } else if approved {
            L("Active")
        } else {
            L("Needs approval")
        }

        return Section {
            Toggle(L("Enabled"), isOn: self.enabledBinding(plugin.manifest.id))
            LabeledContent(L("Status"), value: status)
            LabeledContent(L("File")) {
                Text(Self.displayPath(plugin.fileURL)).textSelection(.enabled)
            }
            LabeledContent(
                L("Origins"),
                value: binding?.origins.joined(separator: ", ") ?? L("Configure endpoint settings"))
            LabeledContent(
                L("Capabilities"),
                value: plugin.manifest.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
                    .nilIfEmpty ?? L("Network"))
            if !plugin.manifest.cookieDomains.isEmpty {
                LabeledContent(
                    L("Cookie domains"),
                    value: plugin.manifest.cookieDomains.sorted().joined(separator: ", "))
            }
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
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !approved {
                    Button(L("Approve…")) { self.requestApproval(plugin: plugin, sourceURL: nil) }
                }
                Button(L("Refresh")) {
                    Task { await self.store.refreshUserPlugin(plugin.manifest.id) }
                }
                Spacer()
                Button(L("Delete…"), role: .destructive) {
                    self.pendingDelete = PluginDeleteRequest(fileURL: plugin.fileURL, plugin: plugin)
                }
            }
        } header: {
            Label(plugin.manifest.name, systemImage: "puzzlepiece.extension")
        }
    }

    private func invalidPluginSection(_ result: UserProviderPluginLoadResult) -> some View {
        Section {
            LabeledContent(L("File")) { Text(Self.displayPath(result.fileURL)).textSelection(.enabled) }
            LabeledContent(L("Status"), value: L("Error"))
            Label(result.error ?? L("Unknown validation error"), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Delete…"), role: .destructive) {
                    self.pendingDelete = PluginDeleteRequest(fileURL: result.fileURL, plugin: nil)
                }
            }
        } header: {
            Label(result.fileURL.deletingPathExtension().lastPathComponent, systemImage: "exclamationmark.triangle")
        }
    }

    private static var pluginsDirectoryDisplayPath: String {
        displayPath(UserProviderPluginLoader.defaultProvidersDirectory)
    }

    private static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func revealPluginsDirectory() {
        let directory = UserProviderPluginLoader.defaultProvidersDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
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
            Text(self.pending.sourceURL == nil ? L("Approve Plugin") : L("Install and Approve Plugin"))
                .font(.title2.bold())
            Text(self.pending.plugin.manifest.name)
            ForEach(self.pending.plugin.manifest.settings.filter { $0.kind == .plain }, id: \.key) { setting in
                TextField(setting.title, text: Binding(
                    get: { self.settings[setting.key] ?? "" },
                    set: { self.settings[setting.key] = $0 }))
            }
            if let binding = self.binding {
                GroupBox(L("Network authority")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(binding.origins, id: \.self) { Text($0).textSelection(.enabled) }
                        Text(L("Auth: %@", binding.authMode))
                        Text(L(
                            "Capabilities: %@",
                            binding.capabilities.joined(separator: ", ").nilIfEmpty ?? L("network")))
                        Text(L("Secrets: %@", binding.secretNames.joined(separator: ", ").nilIfEmpty ?? L("none")))
                        if !binding.cookieDomains.isEmpty {
                            Text(L("Cookie domains: %@", binding.cookieDomains.joined(separator: ", ")))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(binding.typedConfirmationOrigins, id: \.self) { origin in
                    TextField(L("Type %@ to confirm", origin), text: Binding(
                        get: { self.confirmations[origin] ?? "" },
                        set: { self.confirmations[origin] = $0 }))
                }
            } else {
                Text(L("Enter every endpoint setting to review the exact network origins."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel, action: self.onCancel)
                Button(self.pending.sourceURL == nil ? L("Approve") : L("Install")) {
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
