import SwiftUI

struct RootView: View {
    @Environment(SnapshotSyncCoordinator.self) private var coordinator
    @State private var showingSettings = false
    @State private var path = NavigationPath()
    @State private var routed = false

    private var entries: [WidgetSnapshot.ProviderEntry] {
        self.coordinator.snapshot?.enabledEntries ?? []
    }

    var body: some View {
        NavigationStack(path: self.$path) {
            Group {
                if self.entries.isEmpty {
                    EmptyStateView()
                } else {
                    self.content
                }
            }
            .background(BackdropView())
            .navigationTitle("CodexBar")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UsageProvider.self) { provider in
                if let entry = self.coordinator.snapshot?.entries.first(where: { $0.provider == provider }) {
                    ProviderDetailView(entry: entry)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncStatusBadge() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        self.showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: self.$showingSettings) {
                SettingsView()
                    .environment(self.coordinator)
            }
            .refreshable { await self.coordinator.manualRefresh() }
        }
        .onAppear(perform: self.applyLaunchRouting)
        .onChange(of: self.entries.count) { _, _ in self.applyLaunchRouting() }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(self.entries) { entry in
                    NavigationLink(value: entry.provider) {
                        ProviderCardView(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
                SyncFooterView()
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// DEBUG-only deep links for deterministic screenshots (`-screen settings` / `-screen detail`).
    /// Retried when entries load so a detail deep link waits for data rather than no-opping.
    private func applyLaunchRouting() {
        #if DEBUG
        guard !self.routed else { return }
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "-screen"), idx + 1 < args.count else { return }
        switch args[idx + 1] {
        case "settings":
            self.showingSettings = true
            self.routed = true
        case "detail":
            if let first = self.entries.first {
                self.path.append(first.provider)
                self.routed = true
            }
        default:
            self.routed = true
        }
        #endif
    }
}

/// Subtle full-bleed backdrop that lets the glass cards read as translucent.
struct BackdropView: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(hex: "5E5CE6").opacity(0.16),
                Color.clear,
                Color(hex: "30D158").opacity(0.10),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        .ignoresSafeArea()
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// Small pill in the nav bar showing how data last arrived (LAN / iCloud) and its freshness.
struct SyncStatusBadge: View {
    @Environment(SnapshotSyncCoordinator.self) private var coordinator

    private var symbol: String {
        switch self.coordinator.lanStatus {
        case .connected: "wifi"
        case .searching: "wifi.exclamationmark"
        case .idle: self.coordinator.iCloudAvailable ? "icloud" : "icloud.slash"
        }
    }

    private var tint: Color {
        switch self.coordinator.lanStatus {
        case .connected: Color(hex: "30D158")
        case .searching: Color(hex: "FF9F0A")
        case .idle: self.coordinator.iCloudAvailable ? Color(hex: "0A84FF") : .secondary
        }
    }

    var body: some View {
        Image(systemName: self.symbol)
            .foregroundStyle(self.tint)
            .accessibilityLabel("Sync status")
    }
}

/// Footer summarizing the last sync, shown under the card list.
struct SyncFooterView: View {
    @Environment(SnapshotSyncCoordinator.self) private var coordinator

    var body: some View {
        if let metadata = self.coordinator.metadata {
            HStack(spacing: 6) {
                Text("Updated \(UsageFormat.relative(metadata.snapshotGeneratedAt ?? metadata.receivedAt))")
                if let device = metadata.senderDeviceName {
                    Text("· \(device)")
                }
                Text("· via \(metadata.source.displayName)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
        }
    }
}
