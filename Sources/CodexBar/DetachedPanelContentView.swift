import CodexBarCore
import SwiftUI

@MainActor
struct DetachedPanelContentView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    let panelWidth: CGFloat
    let menuCardModelProvider: (UsageProvider?) -> UsageMenuCardView.Model?
    let closePanel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Overview")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    self.closePanel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Panel")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if self.overviewProviders.isEmpty {
                        Text("No usage configured.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: self.panelWidth, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(self.overviewProviders, id: \.self) { provider in
                            if let model = self.menuCardModelProvider(provider) {
                                UsageMenuCardView(model: model, width: self.panelWidth)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(10)
        .frame(width: self.panelWidth + 20, alignment: .leading)
    }

    private var overviewProviders: [UsageProvider] {
        self.settings.resolvedMergedOverviewProviders(activeProviders: self.store.enabledProviders())
    }
}
