import Foundation

@MainActor
extension UsageStore {
    func scheduleMemoryPressureRelief() {
        guard self.memoryPressureReliefTask == nil else { return }

        self.memoryPressureReliefTask = Task.detached(priority: .utility) { [weak self] in
            for delay in [Duration.seconds(2), .seconds(8), .seconds(20)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                MemoryPressureRelief.releaseFreeMallocPages()
            }
            await MainActor.run { [weak self] in
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
