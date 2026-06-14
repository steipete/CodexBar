import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct ImportedCredentialsSectionView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var selectedPlatform = UsageProvider.codex.rawValue
    @State private var selectedFormat = CLIProxyCodexAdapter.format

    var body: some View {
        ProviderSettingsSection(title: L("Imported Credentials")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("Platform"))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                    Picker("", selection: self.$selectedPlatform) {
                        Text("Codex").tag(UsageProvider.codex.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)

                    Spacer(minLength: 0)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("Format"))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                    Picker("", selection: self.$selectedFormat) {
                        Text(CLIProxyCodexAdapter.format).tag(CLIProxyCodexAdapter.format)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)

                    Spacer(minLength: 0)
                }

                Button(L("Add Source…")) {
                    self.addSource()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            let sources = self.settings.importedCodexCredentialSources
            if sources.isEmpty {
                Text(L("No imported credential sources added."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sources) { source in
                        ImportedCredentialSourceRowView(
                            source: source,
                            remove: {
                                self.settings.removeImportedCredentialSource(id: source.id)
                                Task { @MainActor in
                                    await self.store.refreshImportedCodexAccounts()
                                }
                            })
                    }
                }
            }
        }
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = L("Add Imported Credential Source")
        panel.prompt = L("Add")

        guard panel.runModal() == .OK else { return }
        var knownPaths = Set(self.settings.importedCodexCredentialSources.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
        var didAddSource = false
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            guard knownPaths.insert(path).inserted else { continue }
            self.settings.addImportedCredentialSource(ImportedCredentialSource(
                platform: self.selectedPlatform,
                path: path,
                format: self.selectedFormat))
            didAddSource = true
        }

        guard didAddSource else { return }
        Task { @MainActor in
            await self.store.refreshImportedCodexAccounts()
        }
    }
}

@MainActor
private struct ImportedCredentialSourceRowView: View {
    let source: ImportedCredentialSource
    let remove: () -> Void
    @State private var previews: [CLIProxyCodexAccountPreview] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(self.source.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button(L("Remove")) {
                    self.remove()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if self.didLoad {
                if self.previews.isEmpty {
                    Text(L("No Codex accounts detected."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(self.previews) { preview in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(preview.email)
                                    .font(.caption)
                                Text(self.statusText(for: preview))
                                    .font(.caption)
                                    .foregroundStyle(self.statusColor(for: preview))
                            }
                        }
                    }
                }
            } else {
                Text(L("Checking accounts…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: self.source.path) {
            await self.reloadPreview()
        }
    }

    private var title: String {
        if let label = self.source.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty
        {
            return label
        }
        let lastPath = URL(fileURLWithPath: self.source.path).lastPathComponent
        return lastPath.isEmpty ? self.source.path : lastPath
    }

    private func reloadPreview() async {
        let path = self.source.path
        let now = Date()
        let previews = await Task.detached(priority: .utility) {
            CLIProxyCodexAdapter.previewAccounts(from: path, now: now)
        }.value
        self.previews = previews
        self.didLoad = true
    }

    private func statusText(for preview: CLIProxyCodexAccountPreview) -> String {
        if preview.isDisabled { return L("Disabled") }
        if preview.isExpired { return L("Expired") }
        return L("Ready")
    }

    private func statusColor(for preview: CLIProxyCodexAccountPreview) -> Color {
        if preview.isDisabled { return .secondary }
        if preview.isExpired { return .orange }
        return .secondary
    }
}
