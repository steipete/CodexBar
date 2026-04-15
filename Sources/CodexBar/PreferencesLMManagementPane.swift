import AppKit
import CodexBarCore
import SwiftUI

// MARK: - LM Management Pane

/// Unified LM (Language Model) management hub for CodexBar + OpenClaw.
/// Shows all configured providers, their models, health status, Ollama endpoints,
/// and the active fallback chain in one visual dashboard.
@MainActor
struct LMManagementPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var ollamaEndpoints: [OllamaEndpointStatus] = []
    @State private var isProbing = false
    @State private var lastProbeDate: Date?
    @State private var exportOutput: String?
    @State private var showExportSheet = false
    @State private var injectStatus: String?
    @State private var injectSuccess = false
    @State private var discoveredGateways: [DiscoveredGateway] = []
    @State private var isDiscovering = false
    @State private var selectedGatewayPort: Int = 18789
    @State private var showGatewayPicker = false
    @State private var ollamaLoadedModels: [OllamaRunningModel] = []
    @State private var ollamaAllModels: [OllamaInstalledModel] = []
    @State private var systemMemory: SystemMemoryInfo = .init()
    @State private var isLoadingModel = false
    @State private var loadingModelName: String = ""
    @State private var fallbackProviders: [FallbackProvider] = FallbackProvider.loadFromDisk()
    @State private var fallbackDirty = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // Provider overview
                self.providerOverviewSection

                Divider()

                // Ollama Control Panel
                self.ollamaControlSection

                Divider()

                // Ollama endpoints
                self.ollamaEndpointsSection

                Divider()

                // HTTP Local LMs
                self.httpLocalLMSection

                Divider()

                // Fallback chain
                self.fallbackChainSection

                Divider()

                // OpenClaw export & inject
                self.openClawExportSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: self.$showExportSheet) {
            self.exportSheet
        }
        .onAppear {
            self.probeOllamaEndpoints()
            Task { await self.discoverGateways() }
            Task { await self.refreshOllamaState() }
        }
    }

    // MARK: - Provider Overview

    private var providerOverviewSection: some View {
        SettingsSection(contentSpacing: 10) {
            HStack {
                Text("Provider Overview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(self.enabledProviders.count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(self.enabledProviders, id: \.rawValue) { provider in
                self.providerRow(provider)
            }
        }
    }

    private func providerRow(_ provider: UsageProvider) -> some View {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let meta = descriptor.metadata

        return HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(self.providerStatusColor(provider))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.displayName)
                    .font(.body.weight(.medium))

                HStack(spacing: 8) {
                    if meta.supportsOpus {
                        self.badge("Opus", color: .purple)
                    }
                    if meta.supportsCredits {
                        self.badge("Credits", color: .orange)
                    }
                    self.badge(meta.cliName, color: .gray)
                }
            }

            Spacer()

            // Usage summary
            if let snapshot = self.store.snapshot(for: provider) {
                VStack(alignment: .trailing, spacing: 2) {
                    if let primary = snapshot.primary {
                        Text("\(Int(100 - primary.usedPercent))% remaining")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(UsageFormatter.updatedString(from: snapshot.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No data")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Ollama Endpoints

    private var ollamaEndpointsSection: some View {
        SettingsSection(contentSpacing: 10) {
            HStack {
                Text("Ollama Endpoints")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if self.isProbing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("Probing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Refresh") {
                        self.probeOllamaEndpoints()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if self.ollamaEndpoints.isEmpty, !self.isProbing {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.tertiary)
                    Text("No Ollama endpoints detected. Start Ollama locally or configure a LAN endpoint.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(self.ollamaEndpoints, id: \.url) { endpoint in
                    self.ollamaEndpointRow(endpoint)
                }
            }

            if let lastProbe = self.lastProbeDate {
                Text("Last probed: \(UsageFormatter.updatedString(from: lastProbe))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func ollamaEndpointRow(_ endpoint: OllamaEndpointStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(endpoint.isOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.label)
                        .font(.body.weight(.medium))
                    Text(endpoint.url)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Spacer()

                if endpoint.isOnline {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let version = endpoint.version {
                            Text("v\(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(endpoint.modelCount) models")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Offline")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            // Model list (collapsed by default for online endpoints)
            if endpoint.isOnline, !endpoint.models.isEmpty {
                DisclosureGroup("Models") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(endpoint.models, id: \.name) { model in
                            HStack(spacing: 8) {
                                if model.isRunning {
                                    Image(systemName: "bolt.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Text(model.name)
                                    .font(.footnote.monospaced())
                                Spacer()
                                Text(model.sizeLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if model.isReasoning {
                                    self.badge("reasoning", color: .blue)
                                }
                            }
                        }
                    }
                    .padding(.leading, 18)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Fallback Chain

    private var fallbackChainSection: some View {
        SettingsSection(contentSpacing: 10) {
            HStack {
                Text("Fallback Order")
                    .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if self.fallbackDirty {
                    Button("Save") { self.saveFallbackOrder() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }

            Text("Reorder providers with arrows. Accounts within each provider are tried in order before moving to the next provider.")
                .font(.footnote).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(self.fallbackProviders.enumerated()), id: \.element.id) { index, provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Circle().fill(Color.accentColor).frame(width: 20, height: 20)
                            .overlay { Text("\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white) }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName).font(.footnote.weight(.medium))
                            Text(provider.detail).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()

                        if index > 0 {
                            Button { self.moveFallbackProvider(from: index, direction: -1) } label: {
                                Image(systemName: "chevron.up").font(.caption)
                            }.buttonStyle(.borderless)
                        }
                        if index < self.fallbackProviders.count - 1 {
                            Button { self.moveFallbackProvider(from: index, direction: 1) } label: {
                                Image(systemName: "chevron.down").font(.caption)
                            }.buttonStyle(.borderless)
                        }
                    }

                    if !provider.accounts.isEmpty {
                        ForEach(Array(provider.accounts.enumerated()), id: \.element) { accIdx, account in
                            HStack(spacing: 8) {
                                Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2, height: 16)
                                    .padding(.leading, 9)
                                Text(account).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if accIdx > 0 {
                                    Button { self.moveAccount(providerIndex: index, from: accIdx, direction: -1) } label: {
                                        Image(systemName: "chevron.up").font(.system(size: 8))
                                    }.buttonStyle(.borderless)
                                }
                                if accIdx < provider.accounts.count - 1 {
                                    Button { self.moveAccount(providerIndex: index, from: accIdx, direction: 1) } label: {
                                        Image(systemName: "chevron.down").font(.system(size: 8))
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private func moveFallbackProvider(from index: Int, direction: Int) {
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < self.fallbackProviders.count else { return }
        self.fallbackProviders.swapAt(index, newIndex)
        self.fallbackDirty = true
    }

    private func moveAccount(providerIndex: Int, from accIndex: Int, direction: Int) {
        let newIndex = accIndex + direction
        guard newIndex >= 0, newIndex < self.fallbackProviders[providerIndex].accounts.count else { return }
        self.fallbackProviders[providerIndex].accounts.swapAt(accIndex, newIndex)
        self.fallbackDirty = true
    }

    private func saveFallbackOrder() {
        FallbackProvider.saveToDisk(self.fallbackProviders)
        self.fallbackDirty = false
        self.injectStatus = "Fallback order saved — press Inject to apply"
    }

    // MARK: - HTTP Local LM

    private var httpLocalLMSection: some View {
        SettingsSection(contentSpacing: 10) {
            HStack {
                Text("HTTP Local LMs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                self.badge("auto-detected", color: .blue)
            }

            Text("Any local LM server speaking the OpenAI-compatible API at a known endpoint. Ollama, LM Studio, llama.cpp, vLLM, and others are auto-probed.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Show the detected local models across all endpoints
            let onlineEndpoints = self.ollamaEndpoints.filter(\.isOnline)
            let totalModels = onlineEndpoints.reduce(0) { $0 + $1.modelCount }

            if totalModels > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(totalModels) local models available")
                            .font(.body.weight(.medium))
                        Text("across \(onlineEndpoints.count) endpoint\(onlineEndpoints.count == 1 ? "" : "s")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.08))
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.tertiary)
                    Text("No local LM servers detected. Start Ollama or another OpenAI-compatible server.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - OpenClaw Export & Inject

    private var openClawExportSection: some View {
        SettingsSection(contentSpacing: 10) {
            Text("OpenClaw Integration")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text("Push all providers, models, and fallback config directly into your OpenClaw gateway.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Gateway discovery
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Detected Gateways")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if self.isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Scan") { Task { await self.discoverGateways() } }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }

                if self.discoveredGateways.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "network.slash")
                            .foregroundStyle(.tertiary)
                        Text("No OpenClaw gateways detected. Start one and tap Scan.")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }.padding(.vertical, 4)
                } else {
                    ForEach(self.discoveredGateways, id: \.port) { gw in
                        HStack(spacing: 10) {
                            Image(systemName: self.selectedGatewayPort == gw.port ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(self.selectedGatewayPort == gw.port ? .green : .secondary)
                                .onTapGesture { self.selectedGatewayPort = gw.port }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gw.name).font(.footnote.weight(.medium))
                                Text("127.0.0.1:\(gw.port)").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(self.selectedGatewayPort == gw.port ? Color.accentColor.opacity(0.08) : Color.clear)
                        )
                        .onTapGesture { self.selectedGatewayPort = gw.port }
                    }
                }
            }

            // Action buttons
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button("Inject to OpenClaw") {
                        Task { await self.injectToOpenClaw() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(self.discoveredGateways.isEmpty)

                    Button("Preview Export") {
                        Task { await self.generateExport() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button("Copy CLI Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "codexbar-bridge --apply",
                            forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                if let injectStatus = self.injectStatus {
                    HStack(spacing: 6) {
                        Image(systemName: self.injectSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(self.injectSuccess ? .green : .orange)
                        Text(injectStatus)
                            .font(.footnote)
                            .foregroundStyle(self.injectSuccess ? Color.secondary : Color.orange)
                    }
                }
            }
        }
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenClaw Export")
                .font(.headline)

            if let output = self.exportOutput {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 300)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            } else {
                ProgressView("Generating export...")
            }

            HStack {
                Spacer()
                Button("Copy to Clipboard") {
                    if let output = self.exportOutput {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    }
                }
                .disabled(self.exportOutput == nil)

                Button("Close") {
                    self.showExportSheet = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: - Helpers

    private var enabledProviders: [UsageProvider] {
        self.settings.orderedProviders()
    }

    private func providerStatusColor(_ provider: UsageProvider) -> Color {
        if self.store.refreshingProviders.contains(provider) {
            return .yellow
        }
        if self.store.snapshot(for: provider) != nil {
            return .green
        }
        if self.store.errors[provider] != nil {
            return .red
        }
        return .gray
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func probeOllamaEndpoints() {
        guard !self.isProbing else { return }
        self.isProbing = true

        Task {
            let fetcher = OllamaLocalFetcher()
            let endpoints = [OllamaLocalEndpoint.macLocal, OllamaLocalEndpoint.windowsLAN]
            let results = await fetcher.probeAll(endpoints: endpoints)

            self.ollamaEndpoints = results.map { result in
                OllamaEndpointStatus(
                    url: result.endpoint.url,
                    label: result.endpoint.label,
                    isOnline: result.isOnline,
                    version: result.version,
                    modelCount: result.models.count,
                    models: result.models.map { model in
                        OllamaModelStatus(
                            name: model.name,
                            sizeLabel: model.sizeLabel,
                            isRunning: model.isRunning,
                            isReasoning: model.isReasoning)
                    })
            }

            self.lastProbeDate = Date()
            self.isProbing = false
        }
    }

    /// Inject CodexBar config into OpenClaw via authenticated WebSocket RPC.
    ///
    /// Security: Uses gateway token auth over WebSocket — NO file writes,
    /// NO shell scripts, NO kill -9. Everything goes through the gateway API.
    ///
    /// Falls back to legacy shell script if the gateway is not reachable.
    private func injectToOpenClaw() async {
        self.injectStatus = "Preparing export..."
        self.injectSuccess = false

        // Build the export data
        let exporter = OpenClawExporter()
        let fetcher = OllamaLocalFetcher()
        let endpoints = [OllamaLocalEndpoint.macLocal, OllamaLocalEndpoint.windowsLAN]
        let ollamaResults = await fetcher.probeAll(endpoints: endpoints)
        let codexAccounts = CodexAccountInfo.loadManagedAccounts()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        let export = exporter.export(
            ollamaResults: ollamaResults,
            codexAccounts: codexAccounts,
            codexbarVersion: version)

        // Try WebSocket RPC first (secure path)
        let port = self.selectedGatewayPort
        do {
            self.injectStatus = "Connecting to gateway (port \(port))..."

            // Ensure pairing
            let _ = try OpenClawPairing.ensurePaired(port: port)

            // Connect
            let client = OpenClawGatewayClient(port: port)
            try await client.connect()

            do {
                // Get current config + base hash
                self.injectStatus = "Reading gateway config..."
                let snapshot = try await client.configGet()

                // Build merge-patch from export
                let patch = OpenClawPatchBuilder.buildPatch(from: export)

                // Apply patch
                self.injectStatus = "Applying config patch..."
                let result = try await client.configPatch(patch: patch, baseHash: snapshot.baseHash)

                await client.disconnect()

                if result.ok {
                    self.injectSuccess = true
                    self.injectStatus = "Injected via gateway API (port \(port))"
                } else {
                    self.injectSuccess = false
                    self.injectStatus = "Gateway rejected patch"
                }
            } catch {
                await client.disconnect()
                throw error
            }
        } catch {
            // WebSocket failed — fall back to legacy shell script
            self.injectStatus = "Gateway unavailable, falling back to legacy inject..."
            await injectToOpenClawLegacy(export: export)
        }
    }

    /// Legacy fallback: file-write + shell script injection.
    /// Used when the gateway is not running (offline mode).
    private func injectToOpenClawLegacy(export: OpenClawExport) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(export),
              let json = String(data: jsonData, encoding: .utf8)
        else {
            self.injectSuccess = false
            self.injectStatus = "Failed to encode export JSON"
            return
        }

        let exportPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/openclaw-export.json")

        do {
            try FileManager.default.createDirectory(
                at: exportPath.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try json.data(using: .utf8)?.write(to: exportPath, options: .atomic)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: exportPath.path)

            self.injectStatus = "Running legacy inject script..."
            let injectScript = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw/workspace/ops/codexbar-startup-inject.sh")

            if FileManager.default.isExecutableFile(atPath: injectScript.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [injectScript.path]
                process.environment = ProcessInfo.processInfo.environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        self.injectSuccess = true
                        self.injectStatus = "Injected via legacy script (offline mode)"
                    } else {
                        self.injectSuccess = false
                        self.injectStatus = "Legacy inject failed: \(output.suffix(80))"
                    }
                } catch {
                    self.injectSuccess = false
                    self.injectStatus = "Legacy script error: \(error.localizedDescription)"
                }
            } else {
                self.injectSuccess = true
                self.injectStatus = "Exported — run codexbar-inject manually to apply"
            }
        } catch {
            self.injectSuccess = false
            self.injectStatus = "Failed: \(error.localizedDescription)"
        }
    }

    /// Discover running OpenClaw gateways by scanning common ports.
    private func discoverGateways() async {
        self.isDiscovering = true
        var found: [DiscoveredGateway] = []

        let ports = [18789, 19789, 20789, 21789, 22789]
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 2
            return c
        }())

        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["ok"] as? Bool == true
                {
                    let name = port == 18789 ? "OpenClaw (Live)" : "OpenClaw (Port \(port))"
                    found.append(DiscoveredGateway(port: port, name: name, status: "live"))
                }
            } catch {
                // Port not responding — skip
            }
        }

        self.discoveredGateways = found
        if let first = found.first { self.selectedGatewayPort = first.port }
        self.isDiscovering = false
    }

    // MARK: - Ollama Control Panel

    private var ollamaControlSection: some View {
        SettingsSection(contentSpacing: 10) {
            HStack {
                Text("Ollama Control")
                    .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button("Refresh") { Task { await self.refreshOllamaState() } }
                    .buttonStyle(.borderless).font(.caption)
            }

            // System resources
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RAM").font(.caption2).foregroundStyle(.tertiary)
                    Text("\(self.systemMemory.usedGB, specifier: "%.1f") / \(self.systemMemory.totalGB, specifier: "%.0f") GB")
                        .font(.footnote.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU").font(.caption2).foregroundStyle(.tertiary)
                    Text(self.systemMemory.gpuName).font(.footnote.weight(.medium))
                }
                Spacer()
            }
            .padding(.vertical, 4).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

            // Currently loaded models
            VStack(alignment: .leading, spacing: 6) {
                Text("Loaded Models").font(.caption2).foregroundStyle(.tertiary)

                if self.ollamaLoadedModels.isEmpty {
                    Text("No models loaded — select one below to load it")
                        .font(.footnote).foregroundStyle(.tertiary).padding(.vertical, 4)
                } else {
                    ForEach(self.ollamaLoadedModels, id: \.name) { model in
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.fill").foregroundStyle(.green).font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).font(.footnote.weight(.medium))
                                Text("\(model.sizeGB, specifier: "%.1f")GB • \(model.processor) • ctx=\(model.contextLength)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.expiresIn).font(.caption2).foregroundStyle(.tertiary)
                            Button("Eject") {
                                Task { await self.ejectModel(model.name) }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(.red)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.06)))
                    }
                }
            }

            // All installed models
            VStack(alignment: .leading, spacing: 6) {
                Text("Installed Models").font(.caption2).foregroundStyle(.tertiary)

                ForEach(self.ollamaAllModels, id: \.name) { model in
                    HStack(spacing: 10) {
                        let isLoaded = self.ollamaLoadedModels.contains(where: { $0.name == model.name })
                        Image(systemName: isLoaded ? "circle.fill" : "circle")
                            .foregroundStyle(isLoaded ? .green : .gray)
                            .font(.caption2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name).font(.footnote.monospaced())
                            HStack(spacing: 8) {
                                Text("\(model.sizeGB, specifier: "%.1f")GB").font(.caption2).foregroundStyle(.secondary)
                                if model.isEmbedding {
                                    self.badge("embed", color: .gray)
                                }
                                if model.isReasoning {
                                    self.badge("reasoning", color: .blue)
                                }
                                Text("ctx: \(model.contextLength / 1024)k").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if !isLoaded && !model.isEmbedding {
                            if self.isLoadingModel && self.loadingModelName == model.name {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Load") {
                                    Task { await self.loadModel(model.name) }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 2).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
        }
    }

    private func refreshOllamaState() async {
        // System memory
        let totalRAM = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        self.systemMemory = SystemMemoryInfo(
            totalGB: totalRAM,
            usedGB: totalRAM * 0.6, // Approximate — macOS doesn't expose this simply
            gpuName: "Apple Silicon (Unified)")

        let session = URLSession(configuration: .ephemeral)
        let baseURL = "http://127.0.0.1:11434"

        // Running models via /api/ps
        do {
            let (data, _) = try await session.data(from: URL(string: "\(baseURL)/api/ps")!)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]]
            {
                self.ollamaLoadedModels = models.map { m in
                    let sizeVRAM = (m["size_vram"] as? Int64 ?? 0)
                    let size = (m["size"] as? Int64 ?? 0)
                    let expiresAt = m["expires_at"] as? String ?? ""
                    let processor: String
                    if sizeVRAM > 0 && sizeVRAM >= size {
                        processor = "100% GPU"
                    } else if sizeVRAM > 0 {
                        let pct = Int(Double(sizeVRAM) / Double(max(size, 1)) * 100)
                        processor = "\(pct)% GPU"
                    } else {
                        processor = "CPU"
                    }
                    // Parse context from details
                    let details = m["details"] as? [String: Any] ?? [:]
                    let ctx = details["context_length"] as? Int ?? 0

                    return OllamaRunningModel(
                        name: m["name"] as? String ?? "?",
                        sizeGB: Double(size) / 1_073_741_824.0,
                        processor: processor,
                        contextLength: ctx,
                        expiresIn: Self.formatExpiry(expiresAt))
                }
            }
        } catch {}

        // All installed models via /api/tags
        do {
            let (data, _) = try await session.data(from: URL(string: "\(baseURL)/api/tags")!)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]]
            {
                var installed: [OllamaInstalledModel] = []
                for m in models {
                    let name = m["name"] as? String ?? "?"
                    let size = m["size"] as? Int64 ?? 0

                    // Get context window via /api/show
                    var ctx = 131072
                    do {
                        var showReq = URLRequest(url: URL(string: "\(baseURL)/api/show")!)
                        showReq.httpMethod = "POST"
                        showReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        showReq.httpBody = "{\"name\":\"\(name)\"}".data(using: .utf8)
                        let (showData, _) = try await session.data(for: showReq)
                        if let showJSON = try? JSONSerialization.jsonObject(with: showData) as? [String: Any],
                           let info = showJSON["model_info"] as? [String: Any]
                        {
                            for (key, value) in info {
                                let lower = key.lowercased()
                                if lower.contains("original") || lower.contains("rope") { continue }
                                if lower.hasSuffix("context_length") || lower.hasSuffix(".context_length") {
                                    if let c = value as? Int { ctx = c; break }
                                }
                            }
                        }
                    } catch {}

                    let isEmbed = name.contains("embed") || name.contains("nomic") || name.contains("bge")
                    let isReasoning = ["coder", "qwen3", "r1", "think"].contains(where: { name.lowercased().contains($0) })

                    installed.append(OllamaInstalledModel(
                        name: name,
                        sizeGB: Double(size) / 1_073_741_824.0,
                        contextLength: ctx,
                        isEmbedding: isEmbed,
                        isReasoning: isReasoning))
                }
                self.ollamaAllModels = installed.sorted { $0.sizeGB < $1.sizeGB }
            }
        } catch {}
    }

    private func loadModel(_ name: String) async {
        self.isLoadingModel = true
        self.loadingModelName = name

        let session = URLSession(configuration: .ephemeral)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Send empty messages to load without generating
        req.httpBody = "{\"model\":\"\(name)\",\"messages\":[],\"stream\":false}".data(using: .utf8)
        req.timeoutInterval = 120

        _ = try? await session.data(for: req)

        self.isLoadingModel = false
        self.loadingModelName = ""
        await self.refreshOllamaState()
    }

    private func ejectModel(_ name: String) async {
        let session = URLSession(configuration: .ephemeral)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{\"model\":\"\(name)\",\"keep_alive\":0}".data(using: .utf8)

        _ = try? await session.data(for: req)
        await self.refreshOllamaState()
    }

    private static func formatExpiry(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else { return "?" }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "expiring" }
        let mins = Int(remaining / 60)
        if mins < 1 { return "<1m" }
        return "\(mins)m"
    }

    private func generateExport() async {
        self.exportOutput = nil
        self.showExportSheet = true

        let exporter = OpenClawExporter()
        let fetcher = OllamaLocalFetcher()
        let endpoints = [OllamaLocalEndpoint.macLocal, OllamaLocalEndpoint.windowsLAN]
        let ollamaResults = await fetcher.probeAll(endpoints: endpoints)
        let codexAccounts = CodexAccountInfo.loadManagedAccounts()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        let json = exporter.exportJSON(
            ollamaResults: ollamaResults,
            codexAccounts: codexAccounts,
            codexbarVersion: version)

        self.exportOutput = json
    }
}

// MARK: - View Model Types

struct OllamaEndpointStatus: Identifiable {
    let url: String
    let label: String
    let isOnline: Bool
    let version: String?
    let modelCount: Int
    let models: [OllamaModelStatus]

    var id: String { self.url }
}

struct OllamaModelStatus: Identifiable {
    let name: String
    let sizeLabel: String
    let isRunning: Bool
    let isReasoning: Bool

    var id: String { self.name }
}

/// A discovered OpenClaw gateway instance.
struct DiscoveredGateway: Identifiable {
    let port: Int
    let name: String
    let status: String

    var id: Int { self.port }
}

/// A currently loaded/running Ollama model.
struct OllamaRunningModel {
    let name: String
    let sizeGB: Double
    let processor: String     // "100% GPU", "CPU", etc.
    let contextLength: Int
    let expiresIn: String     // "4m", "<1m", "expiring"
}

/// An installed Ollama model (may or may not be loaded).
struct OllamaInstalledModel {
    let name: String
    let sizeGB: Double
    let contextLength: Int
    let isEmbedding: Bool
    let isReasoning: Bool
}

/// System memory info for resource monitoring.
struct SystemMemoryInfo {
    var totalGB: Double = 0
    var usedGB: Double = 0
    var gpuName: String = "Unknown"
}

/// A provider in the fallback order with its accounts.
struct FallbackProvider: Identifiable {
    let id: String           // e.g., "openai-codex", "anthropic", "ollama"
    let displayName: String  // e.g., "Codex (OpenAI)"
    let detail: String       // e.g., "4 accounts"
    var accounts: [String]   // e.g., ["codexbar-d5aa0853", "codexbar-6921f3bf"]
    var models: [String]     // e.g., ["gpt-5.4", "gpt-5.2-codex"]

    static func loadFromDisk() -> [FallbackProvider] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/fallback-order.json")

        if let data = try? Data(contentsOf: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providers = json["providers"] as? [[String: Any]]
        {
            return providers.compactMap { p in
                guard let id = p["id"] as? String else { return nil }
                return FallbackProvider(
                    id: id,
                    displayName: p["displayName"] as? String ?? id,
                    detail: p["detail"] as? String ?? "",
                    accounts: p["accounts"] as? [String] ?? [],
                    models: p["models"] as? [String] ?? [])
            }
        }

        // Default fallback order
        let codexAccounts = CodexAccountInfo.loadManagedAccounts()
        return [
            FallbackProvider(
                id: "openai-codex",
                displayName: "Codex (OpenAI)",
                detail: "\(codexAccounts.count) accounts",
                accounts: codexAccounts.map { "codexbar-\(String($0.accountId.prefix(8)))" },
                models: ["gpt-5.4", "gpt-5.2-codex", "gpt-5.3-codex"]),
            FallbackProvider(
                id: "ollama",
                displayName: "Ollama Local",
                detail: "127.0.0.1:11434",
                accounts: [],
                models: ["gemma4:e4b"]),
        ]
    }

    static func saveToDisk(_ providers: [FallbackProvider]) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/fallback-order.json")

        let json: [String: Any] = [
            "version": 1,
            "providers": providers.map { p in
                [
                    "id": p.id,
                    "displayName": p.displayName,
                    "detail": p.detail,
                    "accounts": p.accounts,
                    "models": p.models,
                ] as [String: Any]
            },
        ]

        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
}
