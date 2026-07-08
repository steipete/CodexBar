import SwiftUI

struct EmptyStateView: View {
    @Environment(SnapshotSyncCoordinator.self) private var coordinator
    var onPair: () -> Void

    private var isPaired: Bool { self.coordinator.hasPairedMac }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: self.isPaired ? "antenna.radiowaves.left.and.right" : "qrcode.viewfinder")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color(hex: "5E5CE6"))
                .padding(24)
                .glassCard(cornerRadius: 28)

            VStack(spacing: 8) {
                Text(self.isPaired ? "Waiting for CodexBar" : "Pair your Mac")
                    .font(.title3.weight(.semibold))
                Text(self.isPaired
                    ? "Paired with \(self.coordinator.pairedMacs.map(\.name).joined(separator: ", ")). Keep both devices on the same Wi-Fi, or sign into the same iCloud account to sync anywhere."
                    : "Open CodexBar on your Mac → Settings → iPhone Sync, then scan the QR code to securely connect this phone. Only your paired Mac can send data — and it's encrypted.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

            if self.isPaired {
                HStack(spacing: 8) {
                    Label(self.coordinator.lanStatus == .connected ? "Mac found" : "Searching Wi-Fi…", systemImage: "wifi")
                    Label(self.coordinator.iCloudAvailable ? "iCloud ready" : "iCloud off", systemImage: "icloud")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    Task { await self.coordinator.manualRefresh() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            } else {
                Button(action: self.onPair) {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
