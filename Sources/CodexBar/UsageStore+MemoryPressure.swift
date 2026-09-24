import Foundation

@MainActor
extension UsageStore {
    func scheduleMemoryPressureRelief() {
        // A completed scan can free a large temporary graph while an earlier relief pass is
        // still waiting. Restart from the latest completion so that graph is reclaimed promptly.
        self.memoryPressureReliefTask?.cancel()
        self.memoryPressureReliefGeneration &+= 1
        let generation = self.memoryPressureReliefGeneration

        self.memoryPressureReliefTask = Task.detached(priority: .utility) { [weak self] in
            for delay in [Duration.milliseconds(500), .seconds(2), .seconds(8)] {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                MemoryPressureRelief.releaseFreeMallocPages()
            }
            await MainActor.run { [weak self] in
                guard self?.memoryPressureReliefGeneration == generation else { return }
                self?.memoryPressureReliefTask = nil
            }
        }
    }

    func trimRebuildableCachesForMemoryPressure() -> MemoryPressureCacheTrimSummary {
        let openAIWebDebugLineCount = self.openAIWebDebugLines.count
        let summary = MemoryPressureCacheTrimSummary(openAIWebDebugLines: openAIWebDebugLineCount)

        self.openAIWebDebugLines.removeAll(keepingCapacity: false)
        self.openAIDashboardCookieImportDebugLog = nil

        return summary
    }

    #if DEBUG
    func seedRebuildableCachesForMemoryPressureProof() {
        self.openAIWebDebugLines = [
            "debug memory pressure line 1",
            "debug memory pressure line 2",
        ]
        self.openAIDashboardCookieImportDebugLog = self.openAIWebDebugLines.joined(separator: "\n")
    }
    #endif
}
