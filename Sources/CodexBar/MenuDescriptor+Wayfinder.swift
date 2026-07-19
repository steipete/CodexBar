import CodexBarCore

extension MenuDescriptor {
    static func appendWayfinderUsageSummary(
        entries: inout [Entry],
        usage: WayfinderUsageSnapshot)
    {
        for line in usage.displayLines {
            entries.append(.text(line, .secondary))
        }
    }
}
