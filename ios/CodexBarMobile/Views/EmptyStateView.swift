import SwiftUI

struct EmptyStateView: View {
    @Environment(SnapshotSyncCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color(hex: "5E5CE6"))
                .padding(24)
                .glassCard(cornerRadius: 28)

            VStack(spacing: 8) {
                Text("Waiting for CodexBar")
                    .font(.title3.weight(.semibold))
                Text("Open CodexBar on your Mac and enable iPhone sync in Settings. Keep both devices on the same Wi-Fi for instant updates, or sign into the same iCloud account to sync anywhere.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Label(
                    self.coordinator.lanStatus == .connected ? "Mac found" : "Searching Wi-Fi…",
                    systemImage: "wifi")
                Label(
                    self.coordinator.iCloudAvailable ? "iCloud ready" : "iCloud off",
                    systemImage: "icloud")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                Task { await self.coordinator.manualRefresh() }
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glassProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
