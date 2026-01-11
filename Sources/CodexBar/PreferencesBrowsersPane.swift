import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct BrowsersPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(
                    title: "Browser cookie sources",
                    caption: "Select which browsers CodexBar can use for cookie-based providers.")
                {
                    ForEach(self.browserEntries) { entry in
                        Toggle(isOn: self.binding(for: entry.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.displayName)
                                    .font(.body)
                                Text(entry.statusText)
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    if self.settings.allowedBrowserIDs.isEmpty {
                        Text("No browsers selected; cookie-based providers will be unavailable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var browserEntries: [BrowserSelectionEntry] {
        BrowserSelectionCatalog.entries(using: self.store.browserDetection)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                self.settings.allowedBrowserIDs.contains(id)
            },
            set: { isEnabled in
                var allowed = self.settings.allowedBrowserIDs
                if isEnabled {
                    allowed.insert(id)
                } else {
                    allowed.remove(id)
                }
                self.settings.allowedBrowserIDs = allowed
            })
    }
}
