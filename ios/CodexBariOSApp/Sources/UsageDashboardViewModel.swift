import CodexBariOSShared
import Foundation
import Observation

@MainActor
@Observable
final class UsageDashboardViewModel {
    var snapshot: iOSWidgetSnapshot?
    var selectedProviderID: String?
    var importJSON = ""
    var importErrorMessage: String?
    var showingImportSheet = false

    var selectedSummary: iOSWidgetSnapshot.ProviderSummary? {
        guard let snapshot else { return nil }
        let selected = snapshot.selectedProviderID(preferred: self.selectedProviderID)
        return snapshot.providerSummaries.first { $0.providerID == selected }
    }

    func loadSnapshot() {
        let snapshot = iOSWidgetSnapshotStore.load()
        let storedProvider = iOSWidgetSnapshotStore.loadSelectedProviderID()
        self.snapshot = snapshot
        self.selectedProviderID = snapshot?.selectedProviderID(preferred: storedProvider ?? self.selectedProviderID)
        self.importErrorMessage = nil
    }

    func loadSampleData() {
        let sample = iOSWidgetPreviewData.snapshot()
        iOSWidgetSnapshotStore.save(sample)
        self.snapshot = sample
        self.selectedProviderID = sample.selectedProviderID(preferred: self.selectedProviderID)
        self.importErrorMessage = nil
    }

    func selectProvider(_ providerID: String) {
        self.selectedProviderID = providerID
        iOSWidgetSnapshotStore.saveSelectedProviderID(providerID)
    }

    func importSnapshotFromJSON() {
        guard let data = self.importJSON.data(using: .utf8) else {
            self.importErrorMessage = "Could not parse pasted text as UTF-8."
            return
        }
        do {
            let snapshot = try iOSWidgetSnapshot.decode(from: data)
            iOSWidgetSnapshotStore.save(snapshot)
            self.snapshot = snapshot
            self.selectedProviderID = snapshot.selectedProviderID(preferred: self.selectedProviderID)
            self.importErrorMessage = nil
            self.showingImportSheet = false
            self.importJSON = ""
        } catch {
            self.importErrorMessage = "Invalid snapshot JSON: \(error.localizedDescription)"
        }
    }
}
