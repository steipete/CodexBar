import CodexBarCore
import SwiftUI

/// Settings home for the per-provider local storage breakdown that the menu shows in its Storage submenu.
@MainActor
struct StoragePane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    var body: some View {
        Form {
            if self.settings.providerStorageScanEnabled {
                Section {
                    self.summary
                        .padding(.vertical, 4)
                } header: {
                    self.summaryHeader
                }
            }

            Section {
                Toggle(isOn: self.showInMenuBinding) {
                    SettingsRowLabel(L("storage_show_in_menu_title"), subtitle: L("storage_show_in_menu_subtitle"))
                }
                .disabled(!self.settings.providerStorageScanEnabled)
            }

            if self.settings.providerStorageScanEnabled {
                ForEach(self.providersWithData, id: \.self) { provider in
                    if let footprint = self.store.storageFootprint(for: provider) {
                        Section {
                            StorageBreakdownMenuView(footprint: footprint, width: 0, embedded: true)
                                .padding(.vertical, 4)
                        } header: {
                            StoragePaneProviderHeader(
                                provider: provider,
                                name: self.store.metadata(for: provider).displayName,
                                bytes: footprint.totalBytes)
                        }
                    }
                }

                let secondary = self.providersWithoutData
                if !secondary.isEmpty {
                    Section {
                        ForEach(secondary, id: \.self) { provider in
                            self.placeholderRow(provider)
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: self.$settings.providerStorageScanEnabled) {
                    SettingsRowLabel(L("storage_scan_title"), subtitle: L("storage_scan_subtitle"))
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .onAppear {
            self.store.scheduleStorageFootprintRefreshForOverview()
        }
        .onChange(of: self.settings.providerStorageScanEnabled) { _, _ in
            self.store.scheduleStorageFootprintRefreshForOverview()
        }
    }

    /// Reads as off while scanning is off, without overwriting the saved preference, so turning scanning back on
    /// restores the user's previous menu choice.
    private var showInMenuBinding: Binding<Bool> {
        Binding(
            get: { self.settings.providerStorageScanEnabled && self.settings.providerStorageFootprintsEnabled },
            set: { self.settings.providerStorageFootprintsEnabled = $0 })
    }

    /// Section header styled like the provider headers: title on the left, total and refresh on the right.
    private var summaryHeader: some View {
        HStack(spacing: 8) {
            Text(L("Storage"))
            Spacer()
            if self.store.isStorageRefreshInFlight {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button {
                    self.store.scheduleStorageFootprintRefreshForOverview(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Refresh"))
                .accessibilityLabel(L("Refresh"))
            }
            Text(UsageFormatter.byteCountString(self.totalBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// All providers on one bar, drawn with the same bar and legend styling as each provider's breakdown.
    @ViewBuilder
    private var summary: some View {
        let slices = self.totalSlices
        if slices.isEmpty {
            Text(L(self.store.isStorageRefreshInFlight ? "Loading…" : "No local data found"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                StorageSegmentBar(
                    slices: slices.map {
                        .init(id: $0.provider.rawValue, name: $0.name, bytes: $0.bytes, color: $0.color)
                    },
                    height: StorageSegmentBar.embeddedHeight)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slices) { slice in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(slice.color)
                                .frame(width: 9, height: 9)
                            Text(slice.name)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(UsageFormatter.byteCountString(slice.bytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private struct TotalSlice: Identifiable {
        var id: UsageProvider {
            self.provider
        }

        let provider: UsageProvider
        let name: String
        let bytes: Int64
        let color: Color
    }

    /// Providers with data, largest first, colored from the same palette as the per-provider bars.
    private var totalSlices: [TotalSlice] {
        let palette = StorageBreakdownMenuView.segmentPalette
        return self.providersWithData
            .compactMap { provider -> (UsageProvider, Int64)? in
                guard let bytes = self.store.storageFootprint(for: provider)?.totalBytes, bytes > 0 else { return nil }
                return (provider, bytes)
            }
            .sorted { $0.1 > $1.1 }
            .enumerated()
            .map { index, entry in
                TotalSlice(
                    provider: entry.0,
                    name: self.store.metadata(for: entry.0).displayName,
                    bytes: entry.1,
                    color: palette[index % palette.count])
            }
    }

    /// Tracked providers still waiting on a running scan show a loading row; once no scan is running, a provider
    /// without data settles to "No local data found", so a row can never stay in a loading state indefinitely.
    private func placeholderRow(_ provider: UsageProvider) -> some View {
        LabeledContent {
            if self.store.storageFootprint(for: provider) == nil, self.store.isStorageRefreshInFlight {
                Text(L("Loading…"))
            } else {
                Text(L("No local data found"))
            }
        } label: {
            StoragePaneProviderLabel(provider: provider, name: self.store.metadata(for: provider).displayName)
        }
        .foregroundStyle(.secondary)
    }

    /// Enabled providers with known local storage paths; the rest have nothing to measure, so they are not listed.
    private var providers: [UsageProvider] {
        self.store.enabledFirstPartyProvidersForDisplay().filter { self.store.isStorageTracked(for: $0) }
    }

    private var providersWithData: [UsageProvider] {
        self.providers.filter { self.store.storageFootprint(for: $0)?.hasLocalData == true }
    }

    private var providersWithoutData: [UsageProvider] {
        self.providers.filter { self.store.storageFootprint(for: $0)?.hasLocalData != true }
    }

    private var totalBytes: Int64 {
        self.providers.reduce(Int64(0)) { partial, provider in
            let bytes = max(self.store.storageFootprint(for: provider)?.totalBytes ?? 0, 0)
            let (sum, overflowed) = partial.addingReportingOverflow(bytes)
            return overflowed ? .max : sum
        }
    }
}

@MainActor
private struct StoragePaneProviderLabel: View {
    let provider: UsageProvider
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let brand = ProviderBrandIcon.image(for: self.provider) {
                    Image(nsImage: brand)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "circle.dotted")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
            Text(self.name)
        }
    }
}

@MainActor
private struct StoragePaneProviderHeader: View {
    let provider: UsageProvider
    let name: String
    let bytes: Int64

    var body: some View {
        HStack(spacing: 8) {
            StoragePaneProviderLabel(provider: self.provider, name: self.name)
            Spacer()
            Text(UsageFormatter.byteCountString(self.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
