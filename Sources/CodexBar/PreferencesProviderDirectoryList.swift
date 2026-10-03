import AppKit
import SwiftUI

@MainActor
struct ProviderSettingsDirectoryListRowView: View {
    let descriptor: ProviderSettingsDirectoryListDescriptor
    @Binding private var paths: [String]

    init(descriptor: ProviderSettingsDirectoryListDescriptor) {
        self.descriptor = descriptor
        self._paths = descriptor.binding
    }

    var body: some View {
        Section {
            ForEach(Array(self.paths.enumerated()), id: \.offset) { _, path in
                HStack {
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer(minLength: 8)
                    Button(L("Remove")) {
                        self.paths.removeAll { $0 == path }
                    }
                    .controlSize(.small)
                    .accessibilityLabel(Text("\(L("Remove")) \(path)"))
                }
            }
            Button(L("Add folder…")) {
                Task { @MainActor in
                    let panel = NSOpenPanel()
                    panel.title = L(self.descriptor.title)
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.showsHiddenFiles = true
                    guard await panel.begin() == .OK else { return }
                    var paths = self.paths
                    for url in panel.urls where !paths.contains(url.path) {
                        paths.append(url.path)
                    }
                    self.paths = paths
                }
            }
        } header: {
            Text(L(self.descriptor.title))
        } footer: {
            SettingsSectionFooter(L(self.descriptor.subtitle))
        }
    }
}
