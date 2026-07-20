import CodexBarCore
import SwiftUI

/// Concept A ("Branded Cards") from the Touch Bar design exploration: one card
/// per provider — logo, then stacked 5h/weekly bars with reset time. No name
/// label: the ~30pt Touch Bar height clips a third text line, and the logo
/// color already identifies the provider. Public `NSTouchBar` API only
/// surfaces this while a window belonging to this app (here: Settings) is
/// key, so it's attached to the `Settings` scene in `CodexbarApp.swift`
/// rather than shown app-wide.
@MainActor
struct CodexBarTouchBarView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var expandedProvider: UsageProvider?

    private let maxCards = 3
    /// Tapping a card leaves the graph up long enough to read, then reverts to the overview
    /// on its own — the Touch Bar has no natural "back" affordance besides tapping again.
    private static let autoRevertSeconds: UInt64 = 8

    var body: some View {
        HStack(spacing: 0) {
            if let expandedProvider, self.cardProviders.contains(expandedProvider) {
                Button {
                    self.expandedProvider = nil
                } label: {
                    TouchBarUsageGraphView(provider: expandedProvider, store: self.store)
                }
                .buttonStyle(.plain)
                .task(id: expandedProvider) {
                    try? await Task.sleep(nanoseconds: Self.autoRevertSeconds * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.expandedProvider = nil
                }
            } else {
                ForEach(Array(self.cardProviders.enumerated()), id: \.element) { index, provider in
                    if index > 0 {
                        Divider()
                    }
                    Button {
                        self.expandedProvider = provider
                    } label: {
                        self.card(for: provider)
                    }
                    .buttonStyle(.plain)
                }
                if self.cardProviders.isEmpty {
                    Text("No providers enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }
            }
        }
    }

    private var cardProviders: [UsageProvider] {
        Array(self.store.enabledProviders().prefix(self.maxCards))
    }

    @ViewBuilder
    private func card(for provider: UsageProvider) -> some View {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let accent = Color(
            red: descriptor.branding.color.red,
            green: descriptor.branding.color.green,
            blue: descriptor.branding.color.blue)
        let snapshot = self.store.snapshot(for: provider)

        HStack(spacing: 7) {
            Circle()
                .fill(accent)
                .frame(width: 20, height: 20)
                .overlay(
                    Group {
                        if let logo = ProviderBrandIcon.image(for: provider) {
                            Image(nsImage: logo)
                                .resizable()
                                .renderingMode(.template)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 11, height: 11)
                        } else {
                            Text(String(descriptor.metadata.displayName.prefix(1)))
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 1) {
                self.rateRow(label: "5h", window: snapshot?.primary, accent: accent)
                self.rateRow(label: "wk", window: snapshot?.secondary, accent: accent)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    @ViewBuilder
    private func rateRow(label: String, window: RateWindow?, accent: Color) -> some View {
        let remaining = 100 - (window?.usedPercent ?? 100)
        let isCritical = remaining < 10

        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(isCritical ? .red : .secondary)
                .frame(width: 14, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(isCritical ? Color.red : accent)
                        .frame(width: geo.size.width * max(0, min(1, remaining / 100)))
                }
            }
            .frame(width: 46, height: 3)

            Text(UsageFormatter.percentString(remaining))
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isCritical ? .red : .primary)
                .frame(width: 28, alignment: .leading)

            if let resetsAt = window?.resetsAt {
                Text(UsageFormatter.resetCountdownDescription(from: resetsAt))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
